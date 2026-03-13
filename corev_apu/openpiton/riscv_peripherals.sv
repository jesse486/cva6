// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 14.11.2018
// Description: Ariane chipset for OpenPiton that includes two bootroms
// (linux, baremetal, both with DTB), debug module, clint and plic.
//
// Note that direct system bus accesses are not yet possible due to a missing
// AXI-lite br_master <-> NOC converter module.
//
// The address bases for the individual peripherals are defined in the
// devices.xml file in OpenPiton, and should be set to
//
// Debug    0xfff1000000 <length 0x1000>
// Boot Rom 0xfff1010000 <length 0x10000>
// CLINT    0xfff1020000 <length 0xc0000>
// PLIC     0xfff1100000 <length 0x4000000>
//
`include "register_interface/assign.svh"
`include "register_interface/typedef.svh"
`include "axi/assign.svh"
`include "axi/typedef.svh"

module riscv_peripherals import ariane_pkg::*; #(
    parameter int unsigned DataWidth       = 64,
    parameter int unsigned NumHarts        =  1,
    parameter int unsigned NumSources      =  1,
    parameter int unsigned PlicMaxPriority =  7,
    parameter bit          SwapEndianess   =  0,
    parameter logic [63:0] DmBase          = 64'hfff1000000,
    parameter logic [63:0] RomBase         = 64'hfff1010000,
    parameter logic [63:0] ClintBase       = 64'hfff1020000,
    parameter logic [63:0] PlicBase        = 64'hfff1100000
) (
    input                               clk_i,
    input                               rst_ni,
    input                               testmode_i,
    // connections to OpenPiton NoC filters
    // Debug/JTAG
    input  [DataWidth-1:0]              buf_ariane_debug_noc2_data_i,
    input                               buf_ariane_debug_noc2_valid_i,
    output                              ariane_debug_buf_noc2_ready_o,
    output [DataWidth-1:0]              ariane_debug_buf_noc3_data_o,
    output                              ariane_debug_buf_noc3_valid_o,
    input                               buf_ariane_debug_noc3_ready_i,
    // Bootrom
    input  [DataWidth-1:0]              buf_ariane_bootrom_noc2_data_i,
    input                               buf_ariane_bootrom_noc2_valid_i,
    output                              ariane_bootrom_buf_noc2_ready_o,
    output [DataWidth-1:0]              ariane_bootrom_buf_noc3_data_o,
    output                              ariane_bootrom_buf_noc3_valid_o,
    input                               buf_ariane_bootrom_noc3_ready_i,
    // CLINT
    input  [DataWidth-1:0]              buf_ariane_clint_noc2_data_i,
    input                               buf_ariane_clint_noc2_valid_i,
    output                              ariane_clint_buf_noc2_ready_o,
    output [DataWidth-1:0]              ariane_clint_buf_noc3_data_o,
    output                              ariane_clint_buf_noc3_valid_o,
    input                               buf_ariane_clint_noc3_ready_i,
    // PLIC
    input [DataWidth-1:0]               buf_ariane_plic_noc2_data_i,
    input                               buf_ariane_plic_noc2_valid_i,
    output                              ariane_plic_buf_noc2_ready_o,
    output [DataWidth-1:0]              ariane_plic_buf_noc3_data_o,
    output                              ariane_plic_buf_noc3_valid_o,
    input                               buf_ariane_plic_noc3_ready_i,
    // APLIC
    input [DataWidth-1:0]               buf_ariane_aplic_noc2_data_i,
    input                               buf_ariane_aplic_noc2_valid_i,
    output                              ariane_aplic_buf_noc2_ready_o,
    output [DataWidth-1:0]              ariane_aplic_buf_noc3_data_o,
    output                              ariane_aplic_buf_noc3_valid_o,
    input                               buf_ariane_aplic_noc3_ready_i,
    // IMSIC MSI bus (software writes MSI vectors here to trigger interrupts)
    input [DataWidth-1:0]               buf_ariane_imsic_noc2_data_i,
    input                               buf_ariane_imsic_noc2_valid_i,
    output                              ariane_imsic_buf_noc2_ready_o,
    output [DataWidth-1:0]              ariane_imsic_buf_noc3_data_o,
    output                              ariane_imsic_buf_noc3_valid_o,
    input                               buf_ariane_imsic_noc3_ready_i,
    // This selects either the BM or linux bootrom
    input                               ariane_boot_sel_i,
    // Debug sigs to cores
    output                              ndmreset_o,    // non-debug module reset
    output                              dmactive_o,    // debug module is active
    output [NumHarts-1:0]               debug_req_o,   // async debug request
    input  [NumHarts-1:0]               unavailable_i, // communicate whether the hart is unavailable (e.g.: power down)
    // JTAG
    input                               tck_i,
    input                               tms_i,
    input                               trst_ni,
    input                               td_i,
    output                              td_o,
    output                              tdo_oe_o,
    // CLINT
    input                               rtc_i,        // Real-time clock in (usually 32.768 kHz)
    output [NumHarts-1:0]               timer_irq_o,  // Timer interrupts
    output [NumHarts-1:0]               ipi_o,        // software interrupt (a.k.a inter-process-interrupt)
    // APLIC
    output [NumHarts*ariane_pkg::NrIntpFiles-1:0]  irq_o,
    // IMSIC
    output imsic_pkg::csr_channel_from_imsic_t  [NumHarts-1:0]   aia_csr_imsic2hart,
    input  imsic_pkg::csr_channel_to_imsic_t    [NumHarts-1:0]   aia_csr_hart2imsic
);

  localparam int unsigned AxiIdWidth    =  1;
  localparam int unsigned AxiAddrWidth  = 64;
  localparam int unsigned AxiDataWidth  = 64;
  localparam int unsigned AxiUserWidth  =  1;

  /////////////////////////////
  // Debug module and JTAG
  /////////////////////////////

  logic          debug_req_valid;
  logic          debug_req_ready;
  logic          debug_resp_valid;
  logic          debug_resp_ready;

  dm::dmi_req_t  debug_req;
  dm::dmi_resp_t debug_resp;

`ifdef RISCV_FESVR_SIM

  initial begin
    $display("[INFO] instantiating FESVR DTM in simulation.");
  end

  // SiFive's SimDTM Module
  // Converts to DPI calls
  logic [31:0] sim_exit; // TODO: wire this up in the testbench
  logic [1:0] debug_req_bits_op;
  assign dmi_req.op = dm::dtm_op_t'(debug_req_bits_op);

  SimDTM i_SimDTM (
    .clk                  ( clk_i                ),
    .reset                ( ~rst_ni              ),
    .debug_req_valid      ( debug_req_valid      ),
    .debug_req_ready      ( debug_req_ready      ),
    .debug_req_bits_addr  ( debug_req.addr       ),
    .debug_req_bits_op    ( debug_req_bits_op    ),
    .debug_req_bits_data  ( debug_req.data       ),
    .debug_resp_valid     ( debug_resp_valid     ),
    .debug_resp_ready     ( debug_resp_ready       ),
    .debug_resp_bits_resp ( debug_resp.resp      ),
    .debug_resp_bits_data ( debug_resp.data      ),
    .exit                 ( sim_exit             )
  );

`else // RISCV_FESVR_SIM

  logic        tck, tms, trst_n, tdi, tdo, tdo_oe;

  dmi_jtag i_dmi_jtag (
    .clk_i                                ,
    .rst_ni                               ,
    .testmode_i                           ,
    .dmi_req_o        ( debug_req        ),
    .dmi_req_valid_o  ( debug_req_valid  ),
    .dmi_req_ready_i  ( debug_req_ready  ),
    .dmi_resp_i       ( debug_resp       ),
    .dmi_resp_ready_o ( debug_resp_ready ),
    .dmi_resp_valid_i ( debug_resp_valid ),
    .dmi_rst_no       (                  ), // not connected
    .tck_i            ( tck              ),
    .tms_i            ( tms              ),
    .trst_ni          ( trst_n           ),
    .td_i             ( tdi              ),
    .td_o             ( tdo              ),
    .tdo_oe_o         ( tdo_oe           )
  );

`ifdef RISCV_JTAG_SIM

  initial begin
    $display("[INFO] instantiating JTAG DTM in simulation.");
  end

  // SiFive's SimJTAG Module
  // Converts to DPI calls
  logic [31:0] sim_exit; // TODO: wire this up in the testbench
  SimJTAG i_SimJTAG (
    .clock                ( clk_i                ),
    .reset                ( ~rst_ni              ),
    .enable               ( jtag_enable[0]       ),
    .init_done            ( init_done            ),
    .jtag_TCK             ( tck                  ),
    .jtag_TMS             ( tms                  ),
    .jtag_TDI             ( trst_n               ),
    .jtag_TRSTn           ( td                   ),
    .jtag_TDO_data        ( td                   ),
    .jtag_TDO_driven      ( tdo_oe               ),
    .exit                 ( sim_exit             )
  );

  assign td_o     = 1'b0  ;
  assign tdo_oe_o = 1'b0  ;

`else // RISCV_JTAG_SIM

  assign tck      = tck_i   ;
  assign tms      = tms_i   ;
  assign trst_n   = trst_ni ;
  assign tdi      = td_i    ;
  assign td_o     = tdo     ;
  assign tdo_oe_o = tdo_oe  ;

`endif // RISCV_JTAG_SIM
`endif // RISCV_FESVR_SIM

  logic                dm_slave_req;
  logic                dm_slave_we;
  logic [64-1:0]       dm_slave_addr;
  logic [64/8-1:0]     dm_slave_be;
  logic [64-1:0]       dm_slave_wdata;
  logic [64-1:0]       dm_slave_rdata;

  logic                dm_master_req;
  logic [64-1:0]       dm_master_add;
  logic                dm_master_we;
  logic [64-1:0]       dm_master_wdata;
  logic [64/8-1:0]     dm_master_be;
  logic                dm_master_gnt;
  logic                dm_master_r_valid;
  logic [64-1:0]       dm_master_r_rdata;

  // debug module
  dm_top #(
    .NrHarts              ( NumHarts             ),
    .BusWidth             ( AxiDataWidth         ),
    .SelectableHarts      ( {NumHarts{1'b1}}     )
  ) i_dm_top (
    .clk_i                                        ,
    .rst_ni                                       , // PoR
    .testmode_i                                   ,
    .ndmreset_o                                   ,
    .dmactive_o                                   , // active debug session
    .debug_req_o                                  ,
    .unavailable_i                                ,
    .hartinfo_i           ( {NumHarts{ariane_pkg::DebugHartInfo}} ),
    .slave_req_i          ( dm_slave_req         ),
    .slave_we_i           ( dm_slave_we          ),
    .slave_addr_i         ( dm_slave_addr        ),
    .slave_be_i           ( dm_slave_be          ),
    .slave_wdata_i        ( dm_slave_wdata       ),
    .slave_rdata_o        ( dm_slave_rdata       ),
    .master_req_o         ( dm_master_req        ),
    .master_add_o         ( dm_master_add        ),
    .master_we_o          ( dm_master_we         ),
    .master_wdata_o       ( dm_master_wdata      ),
    .master_be_o          ( dm_master_be         ),
    .master_gnt_i         ( dm_master_gnt        ),
    .master_r_valid_i     ( dm_master_r_valid    ),
    .master_r_rdata_i     ( dm_master_r_rdata    ),
    .dmi_rst_ni           ( rst_ni               ),
    .dmi_req_valid_i      ( debug_req_valid      ),
    .dmi_req_ready_o      ( debug_req_ready      ),
    .dmi_req_i            ( debug_req            ),
    .dmi_resp_valid_o     ( debug_resp_valid     ),
    .dmi_resp_ready_i     ( debug_resp_ready     ),
    .dmi_resp_o           ( debug_resp           )
  );

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( AxiAddrWidth     ),
      .AXI_DATA_WIDTH ( AxiDataWidth     ),
      .AXI_ID_WIDTH   ( AxiIdWidth       ),
      .AXI_USER_WIDTH ( AxiUserWidth     )
  ) dm_master();

  axi2mem #(
      .AXI_ID_WIDTH   ( AxiIdWidth   ),
      .AXI_ADDR_WIDTH ( AxiAddrWidth ),
      .AXI_DATA_WIDTH ( AxiDataWidth ),
      .AXI_USER_WIDTH ( AxiUserWidth )
  ) i_dm_axi2mem (
      .clk_i      ( clk_i                     ),
      .rst_ni     ( rst_ni                    ),
      .slave      ( dm_master                 ),
      .req_o      ( dm_slave_req              ),
      .we_o       ( dm_slave_we               ),
      .addr_o     ( dm_slave_addr             ),
      .be_o       ( dm_slave_be               ),
      .data_o     ( dm_slave_wdata            ),
      .data_i     ( dm_slave_rdata            )
  );

  noc_axilite_bridge #(
    .SLAVE_RESP_BYTEWIDTH   ( 8             ),
    .SWAP_ENDIANESS         ( SwapEndianess )
  ) i_debug_axilite_bridge (
    .clk                    ( clk_i                         ),
    .rst                    ( ~rst_ni                       ),
    // to/from NOC
    .splitter_bridge_val    ( buf_ariane_debug_noc2_valid_i ),
    .splitter_bridge_data   ( buf_ariane_debug_noc2_data_i  ),
    .bridge_splitter_rdy    ( ariane_debug_buf_noc2_ready_o ),
    .bridge_splitter_val    ( ariane_debug_buf_noc3_valid_o ),
    .bridge_splitter_data   ( ariane_debug_buf_noc3_data_o  ),
    .splitter_bridge_rdy    ( buf_ariane_debug_noc3_ready_i ),
    //axi lite signals
    //write address channel
    .m_axi_awaddr           ( dm_master.aw_addr             ),
    .m_axi_awvalid          ( dm_master.aw_valid            ),
    .m_axi_awready          ( dm_master.aw_ready            ),
    //write data channel
    .m_axi_wdata            ( dm_master.w_data              ),
    .m_axi_wstrb            ( dm_master.w_strb              ),
    .m_axi_wvalid           ( dm_master.w_valid             ),
    .m_axi_wready           ( dm_master.w_ready             ),
    //read address channel
    .m_axi_araddr           ( dm_master.ar_addr             ),
    .m_axi_arvalid          ( dm_master.ar_valid            ),
    .m_axi_arready          ( dm_master.ar_ready            ),
    //read data channel
    .m_axi_rdata            ( dm_master.r_data              ),
    .m_axi_rresp            ( dm_master.r_resp              ),
    .m_axi_rvalid           ( dm_master.r_valid             ),
    .m_axi_rready           ( dm_master.r_ready             ),
    //write response channel
    .m_axi_bresp            ( dm_master.b_resp              ),
    .m_axi_bvalid           ( dm_master.b_valid             ),
    .m_axi_bready           ( dm_master.b_ready             ),
    // non-axi-lite signals
    .w_reqbuf_size          (                               ),
    .r_reqbuf_size          (                               )
  );

  // tie off system bus accesses (not supported yet due to
  // missing AXI-lite br_master <-> NOC converter)
  assign dm_master_gnt      = '0;
  assign dm_master_r_valid  = '0;
  assign dm_master_r_rdata  = '0;

  // tie off signals not used by AXI-lite
  assign dm_master.aw_id     = '0;
  assign dm_master.aw_len    = '0;
  assign dm_master.aw_size   = 3'b11;// 8byte
  assign dm_master.aw_burst  = '0;
  assign dm_master.aw_lock   = '0;
  assign dm_master.aw_cache  = '0;
  assign dm_master.aw_prot   = '0;
  assign dm_master.aw_qos    = '0;
  assign dm_master.aw_region = '0;
  assign dm_master.aw_atop   = '0;
  assign dm_master.w_last    = 1'b1;
  assign dm_master.ar_id     = '0;
  assign dm_master.ar_len    = '0;
  assign dm_master.ar_size   = 3'b11;// 8byte
  assign dm_master.ar_burst  = '0;
  assign dm_master.ar_lock   = '0;
  assign dm_master.ar_cache  = '0;
  assign dm_master.ar_prot   = '0;
  assign dm_master.ar_qos    = '0;
  assign dm_master.ar_region = '0;


  /////////////////////////////
  // Bootrom
  /////////////////////////////

  logic                    rom_req;
  logic [AxiAddrWidth-1:0] rom_addr;
  logic [AxiDataWidth-1:0] rom_rdata, rom_rdata_bm, rom_rdata_linux;

  AXI_BUS #(
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) br_master();

  axi2mem #(
    .AXI_ID_WIDTH   ( AxiIdWidth    ),
    .AXI_ADDR_WIDTH ( AxiAddrWidth  ),
    .AXI_DATA_WIDTH ( AxiDataWidth  ),
    .AXI_USER_WIDTH ( AxiUserWidth  )
  ) i_axi2rom (
    .clk_i                ,
    .rst_ni               ,
    .slave  ( br_master  ),
    .req_o  ( rom_req    ),
    .we_o   (            ),
    .addr_o ( rom_addr   ),
    .be_o   (            ),
    .data_o (            ),
    .data_i ( rom_rdata  )
  );

  bootrom i_bootrom_bm (
    .clk_i                   ,
    .req_i      ( rom_req   ),
    .addr_i     ( rom_addr  ),
    .rdata_o    ( rom_rdata_bm )
  );

  bootrom_linux i_bootrom_linux (
    .clk_i                   ,
    .req_i      ( rom_req   ),
    .addr_i     ( rom_addr  ),
    .rdata_o    ( rom_rdata_linux )
  );

  // we want to run in baremetal mode when using pitonstream
  assign rom_rdata = (ariane_boot_sel_i) ? rom_rdata_bm : rom_rdata_linux;

  noc_axilite_bridge #(
    .SLAVE_RESP_BYTEWIDTH   ( 8             ),
    .SWAP_ENDIANESS         ( SwapEndianess )
  ) i_bootrom_axilite_bridge (
    .clk                    ( clk_i                           ),
    .rst                    ( ~rst_ni                         ),
    // to/from NOC
    .splitter_bridge_val    ( buf_ariane_bootrom_noc2_valid_i ),
    .splitter_bridge_data   ( buf_ariane_bootrom_noc2_data_i  ),
    .bridge_splitter_rdy    ( ariane_bootrom_buf_noc2_ready_o ),
    .bridge_splitter_val    ( ariane_bootrom_buf_noc3_valid_o ),
    .bridge_splitter_data   ( ariane_bootrom_buf_noc3_data_o  ),
    .splitter_bridge_rdy    ( buf_ariane_bootrom_noc3_ready_i ),
    //axi lite signals
    //write address channel
    .m_axi_awaddr           ( br_master.aw_addr               ),
    .m_axi_awvalid          ( br_master.aw_valid              ),
    .m_axi_awready          ( br_master.aw_ready              ),
    //write data channel
    .m_axi_wdata            ( br_master.w_data                ),
    .m_axi_wstrb            ( br_master.w_strb                ),
    .m_axi_wvalid           ( br_master.w_valid               ),
    .m_axi_wready           ( br_master.w_ready               ),
    //read address channel
    .m_axi_araddr           ( br_master.ar_addr               ),
    .m_axi_arvalid          ( br_master.ar_valid              ),
    .m_axi_arready          ( br_master.ar_ready              ),
    //read data channel
    .m_axi_rdata            ( br_master.r_data                ),
    .m_axi_rresp            ( br_master.r_resp                ),
    .m_axi_rvalid           ( br_master.r_valid               ),
    .m_axi_rready           ( br_master.r_ready               ),
    //write response channel
    .m_axi_bresp            ( br_master.b_resp                ),
    .m_axi_bvalid           ( br_master.b_valid               ),
    .m_axi_bready           ( br_master.b_ready               ),
    // non-axi-lite signals
    .w_reqbuf_size          (                                 ),
    .r_reqbuf_size          (                                 )
  );

  // tie off signals not used by AXI-lite
  assign br_master.aw_id     = '0;
  assign br_master.aw_len    = '0;
  assign br_master.aw_size   = 3'b11;// 8byte
  assign br_master.aw_burst  = '0;
  assign br_master.aw_lock   = '0;
  assign br_master.aw_cache  = '0;
  assign br_master.aw_prot   = '0;
  assign br_master.aw_qos    = '0;
  assign br_master.aw_region = '0;
  assign br_master.aw_atop   = '0;
  assign br_master.w_last    = 1'b1;
  assign br_master.ar_id     = '0;
  assign br_master.ar_len    = '0;
  assign br_master.ar_size   = 3'b11;// 8byte
  assign br_master.ar_burst  = '0;
  assign br_master.ar_lock   = '0;
  assign br_master.ar_cache  = '0;
  assign br_master.ar_prot   = '0;
  assign br_master.ar_qos    = '0;
  assign br_master.ar_region = '0;

  /////////////////////////////
  // CLINT
  /////////////////////////////

  ariane_axi::req_t    clint_axi_req;
  ariane_axi::resp_t   clint_axi_resp;

  clint #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .NR_CORES       ( NumHarts     )
  ) i_clint (
    .clk_i                         ,
    .rst_ni                        ,
    .testmode_i                    ,
    .axi_req_i   ( clint_axi_req  ),
    .axi_resp_o  ( clint_axi_resp ),
    .rtc_i                         ,
    .timer_irq_o                   ,
    .ipi_o
  );

  noc_axilite_bridge #(
    .SLAVE_RESP_BYTEWIDTH   ( 8             ),
    .SWAP_ENDIANESS         ( SwapEndianess )
  ) i_clint_axilite_bridge (
    .clk                    ( clk_i                         ),
    .rst                    ( ~rst_ni                       ),
    // to/from NOC
    .splitter_bridge_val    ( buf_ariane_clint_noc2_valid_i ),
    .splitter_bridge_data   ( buf_ariane_clint_noc2_data_i  ),
    .bridge_splitter_rdy    ( ariane_clint_buf_noc2_ready_o ),
    .bridge_splitter_val    ( ariane_clint_buf_noc3_valid_o ),
    .bridge_splitter_data   ( ariane_clint_buf_noc3_data_o  ),
    .splitter_bridge_rdy    ( buf_ariane_clint_noc3_ready_i ),
    //axi lite signals
    //write address channel
    .m_axi_awaddr           ( clint_axi_req.aw.addr         ),
    .m_axi_awvalid          ( clint_axi_req.aw_valid        ),
    .m_axi_awready          ( clint_axi_resp.aw_ready       ),
    //write data channel
    .m_axi_wdata            ( clint_axi_req.w.data          ),
    .m_axi_wstrb            ( clint_axi_req.w.strb          ),
    .m_axi_wvalid           ( clint_axi_req.w_valid         ),
    .m_axi_wready           ( clint_axi_resp.w_ready        ),
    //read address channel
    .m_axi_araddr           ( clint_axi_req.ar.addr         ),
    .m_axi_arvalid          ( clint_axi_req.ar_valid        ),
    .m_axi_arready          ( clint_axi_resp.ar_ready       ),
    //read data channel
    .m_axi_rdata            ( clint_axi_resp.r.data         ),
    .m_axi_rresp            ( clint_axi_resp.r.resp         ),
    .m_axi_rvalid           ( clint_axi_resp.r_valid        ),
    .m_axi_rready           ( clint_axi_req.r_ready         ),
    //write response channel
    .m_axi_bresp            ( clint_axi_resp.b.resp         ),
    .m_axi_bvalid           ( clint_axi_resp.b_valid        ),
    .m_axi_bready           ( clint_axi_req.b_ready         ),
    // non-axi-lite signals
    .w_reqbuf_size          (                               ),
    .r_reqbuf_size          (                               )
  );

  // tie off signals not used by AXI-lite
  assign clint_axi_req.aw.id     = '0;
  assign clint_axi_req.aw.len    = '0;
  assign clint_axi_req.aw.size   = 3'b11;// 8byte
  assign clint_axi_req.aw.burst  = '0;
  assign clint_axi_req.aw.lock   = '0;
  assign clint_axi_req.aw.cache  = '0;
  assign clint_axi_req.aw.prot   = '0;
  assign clint_axi_req.aw.qos    = '0;
  assign clint_axi_req.aw.region = '0;
  assign clint_axi_req.aw.atop   = '0;
  assign clint_axi_req.w.last    = 1'b1;
  assign clint_axi_req.ar.id     = '0;
  assign clint_axi_req.ar.len    = '0;
  assign clint_axi_req.ar.size   = 3'b11;// 8byte
  assign clint_axi_req.ar.burst  = '0;
  assign clint_axi_req.ar.lock   = '0;
  assign clint_axi_req.ar.cache  = '0;
  assign clint_axi_req.ar.prot   = '0;
  assign clint_axi_req.ar.qos    = '0;
  assign clint_axi_req.ar.region = '0;

  /////////////////////////////
  // APLIC & IMSIC
  /////////////////////////////

  AXI_BUS #(
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) aplic_master();

  AXI_BUS #(
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) imsic_master();

  noc_axilite_bridge #(
    // this enables variable width accesses
    // note that the accesses are still 64bit, but the
    // write-enables are generated according to the access size
    .SLAVE_RESP_BYTEWIDTH   ( 0             ),
    .SWAP_ENDIANESS         ( SwapEndianess ),
    // this disables shifting of unaligned read data
    .ALIGN_RDATA            ( 0             )
  ) i_aplic_axilite_bridge (
    .clk                    ( clk_i                        ),
    .rst                    ( ~rst_ni                      ),
    // to/from NOC
    .splitter_bridge_val    ( buf_ariane_aplic_noc2_valid_i ),
    .splitter_bridge_data   ( buf_ariane_aplic_noc2_data_i  ),
    .bridge_splitter_rdy    ( ariane_aplic_buf_noc2_ready_o ),
    .bridge_splitter_val    ( ariane_aplic_buf_noc3_valid_o ),
    .bridge_splitter_data   ( ariane_aplic_buf_noc3_data_o  ),
    .splitter_bridge_rdy    ( buf_ariane_aplic_noc3_ready_i ),
    //axi lite signals
    //write address channel
    .m_axi_awaddr           ( aplic_master.aw_addr               ),
    .m_axi_awvalid          ( aplic_master.aw_valid              ),
    .m_axi_awready          ( aplic_master.aw_ready              ),
    //write data channel
    .m_axi_wdata            ( aplic_master.w_data                ),
    .m_axi_wstrb            ( aplic_master.w_strb                ),
    .m_axi_wvalid           ( aplic_master.w_valid               ),
    .m_axi_wready           ( aplic_master.w_ready               ),
    //read address channel
    .m_axi_araddr           ( aplic_master.ar_addr               ),
    .m_axi_arvalid          ( aplic_master.ar_valid              ),
    .m_axi_arready          ( aplic_master.ar_ready              ),
    //read data channel
    .m_axi_rdata            ( aplic_master.r_data                ),
    .m_axi_rresp            ( aplic_master.r_resp                ),
    .m_axi_rvalid           ( aplic_master.r_valid               ),
    .m_axi_rready           ( aplic_master.r_ready               ),
    //write response channel
    .m_axi_bresp            ( aplic_master.b_resp                ),
    .m_axi_bvalid           ( aplic_master.b_valid               ),
    .m_axi_bready           ( aplic_master.b_ready               ),
    // non-axi-lite signals
    .w_reqbuf_size          ( aplic_master.aw_size               ),
    .r_reqbuf_size          ( aplic_master.ar_size               )
  );

  // tie off signals not used by AXI-lite
  assign aplic_master.aw_id     = '0;
  assign aplic_master.aw_len    = '0;
  assign aplic_master.aw_burst  = '0;
  assign aplic_master.aw_lock   = '0;
  assign aplic_master.aw_cache  = '0;
  assign aplic_master.aw_prot   = '0;
  assign aplic_master.aw_qos    = '0;
  assign aplic_master.aw_region = '0;
  assign aplic_master.aw_atop   = '0;
  assign aplic_master.w_last    = 1'b1;
  assign aplic_master.ar_id     = '0;
  assign aplic_master.ar_len    = '0;
  assign aplic_master.ar_burst  = '0;
  assign aplic_master.ar_lock   = '0;
  assign aplic_master.ar_cache  = '0;
  assign aplic_master.ar_prot   = '0;
  assign aplic_master.ar_qos    = '0;
  assign aplic_master.ar_region = '0;

  noc_axilite_bridge #(
    // this enables variable width accesses
    // note that the accesses are still 64bit, but the
    // write-enables are generated according to the access size
    .SLAVE_RESP_BYTEWIDTH   ( 0             ),
    .SWAP_ENDIANESS         ( SwapEndianess ),
    // this disables shifting of unaligned read data
    .ALIGN_RDATA            ( 0             )
  ) i_imsic_axilite_bridge (
    .clk                    ( clk_i                        ),
    .rst                    ( ~rst_ni                      ),
    // to/from NOC
    .splitter_bridge_val    ( buf_ariane_imsic_noc2_valid_i ),
    .splitter_bridge_data   ( buf_ariane_imsic_noc2_data_i  ),
    .bridge_splitter_rdy    ( ariane_imsic_buf_noc2_ready_o ),
    .bridge_splitter_val    ( ariane_imsic_buf_noc3_valid_o ),
    .bridge_splitter_data   ( ariane_imsic_buf_noc3_data_o  ),
    .splitter_bridge_rdy    ( buf_ariane_imsic_noc3_ready_i ),
    //axi lite signals
    //write address channel
    .m_axi_awaddr           ( imsic_master.aw_addr               ),
    .m_axi_awvalid          ( imsic_master.aw_valid              ),
    .m_axi_awready          ( imsic_master.aw_ready              ),
    //write data channel
    .m_axi_wdata            ( imsic_master.w_data                ),
    .m_axi_wstrb            ( imsic_master.w_strb                ),
    .m_axi_wvalid           ( imsic_master.w_valid               ),
    .m_axi_wready           ( imsic_master.w_ready               ),
    //read address channel
    .m_axi_araddr           ( imsic_master.ar_addr               ),
    .m_axi_arvalid          ( imsic_master.ar_valid              ),
    .m_axi_arready          ( imsic_master.ar_ready              ),
    //read data channel
    .m_axi_rdata            ( imsic_master.r_data                ),
    .m_axi_rresp            ( imsic_master.r_resp                ),
    .m_axi_rvalid           ( imsic_master.r_valid               ),
    .m_axi_rready           ( imsic_master.r_ready               ),
    //write response channel
    .m_axi_bresp            ( imsic_master.b_resp                ),
    .m_axi_bvalid           ( imsic_master.b_valid               ),
    .m_axi_bready           ( imsic_master.b_ready               ),
    // non-axi-lite signals
    .w_reqbuf_size          ( imsic_master.aw_size               ),
    .r_reqbuf_size          ( imsic_master.ar_size               )
  );

  // tie off signals not used by AXI-lite
  assign imsic_master.aw_id     = '0;
  assign imsic_master.aw_len    = '0;
  assign imsic_master.aw_burst  = '0;
  assign imsic_master.aw_lock   = '0;
  assign imsic_master.aw_cache  = '0;
  assign imsic_master.aw_prot   = '0;
  assign imsic_master.aw_qos    = '0;
  assign imsic_master.aw_region = '0;
  assign imsic_master.aw_atop   = '0;
  assign imsic_master.w_last    = 1'b1;
  assign imsic_master.ar_id     = '0;
  assign imsic_master.ar_len    = '0;
  assign imsic_master.ar_burst  = '0;
  assign imsic_master.ar_lock   = '0;
  assign imsic_master.ar_cache  = '0;
  assign imsic_master.ar_prot   = '0;
  assign imsic_master.ar_qos    = '0;
  assign imsic_master.ar_region = '0;

  // irq_sources
  localparam int unsigned UART_IRQ         = 32'd0;
  localparam int unsigned SPI_IRQ          = 32'd1;
  localparam int unsigned ETH_IRQ          = 32'd2;
  localparam int unsigned TIMER_FIRST_IRQ  = 32'd3;
  localparam int unsigned TIMER_LAST_IRQ   = 32'd6;
  localparam int unsigned LAST_IRQ         = TIMER_LAST_IRQ + 1;
  logic [ariane_soc::NumSources-1:0] irq_sources;

  // Unused interrupt sources
  assign irq_sources[ariane_soc::NumSources-1:LAST_IRQ] = '0;

  // APLIC configuration Bus (AXI => APB => REG)
  ariane_axi_soc::req_slv_t  aplic_cfg_req;
  ariane_axi_soc::resp_slv_t aplic_cfg_rsp;
  `AXI_ASSIGN_TO_REQ(aplic_cfg_req, aplic_master)
  `AXI_ASSIGN_FROM_RESP(aplic_master, aplic_cfg_rsp)

  REG_BUS #(
    .ADDR_WIDTH ( 32 ),
    .DATA_WIDTH ( 32 )
  ) aplic_reg_bus (clk_i);

  logic         aplic_penable;
  logic         aplic_pwrite;
  logic [31:0]  aplic_paddr;
  logic         aplic_psel;
  logic [31:0]  aplic_pwdata;
  logic [31:0]  aplic_prdata;
  logic         aplic_pready;
  logic         aplic_pslverr;

    axi2apb_64_32 #(
        .AXI4_ADDRESS_WIDTH ( AxiAddrWidth  ),
        .AXI4_RDATA_WIDTH   ( AxiDataWidth  ),
        .AXI4_WDATA_WIDTH   ( AxiDataWidth  ),
        .AXI4_ID_WIDTH      ( AxiIdWidth    ),
        .AXI4_USER_WIDTH    ( AxiUserWidth  ),
        .BUFF_DEPTH_SLAVE   ( 2             ),
        .APB_ADDR_WIDTH     ( 32            )
    ) i_axi2apb_64_32_aplic (
        .ACLK      ( clk_i          ),
        .ARESETn   ( rst_ni         ),
        .test_en_i ( 1'b0           ),
        // AW
        .AWID_i    ( aplic_cfg_req.aw.id     ),
        .AWADDR_i  ( aplic_cfg_req.aw.addr   ),
        .AWLEN_i   ( aplic_cfg_req.aw.len    ),
        .AWSIZE_i  ( aplic_cfg_req.aw.size   ),
        .AWBURST_i ( aplic_cfg_req.aw.burst  ),
        .AWLOCK_i  ( aplic_cfg_req.aw.lock   ),
        .AWCACHE_i ( aplic_cfg_req.aw.cache  ),
        .AWPROT_i  ( aplic_cfg_req.aw.prot   ),
        .AWREGION_i( aplic_cfg_req.aw.region ),
        .AWUSER_i  ( aplic_cfg_req.aw.user   ),
        .AWQOS_i   ( aplic_cfg_req.aw.qos    ),
        .AWVALID_i ( aplic_cfg_req.aw_valid  ),
        .AWREADY_o ( aplic_cfg_rsp.aw_ready ),
        // W
        .WDATA_i   ( aplic_cfg_req.w.data    ),
        .WSTRB_i   ( aplic_cfg_req.w.strb    ),
        .WLAST_i   ( aplic_cfg_req.w.last    ),
        .WUSER_i   ( aplic_cfg_req.w.user    ),
        .WVALID_i  ( aplic_cfg_req.w_valid   ),
        .WREADY_o  ( aplic_cfg_rsp.w_ready  ),
        // B
        .BID_o     ( aplic_cfg_rsp.b.id     ),
        .BRESP_o   ( aplic_cfg_rsp.b.resp   ),
        .BUSER_o   ( aplic_cfg_rsp.b.user   ),
        .BVALID_o  ( aplic_cfg_rsp.b_valid  ),
        .BREADY_i  ( aplic_cfg_req.b_ready   ),
        // AR
        .ARID_i    ( aplic_cfg_req.ar.id     ),
        .ARADDR_i  ( aplic_cfg_req.ar.addr   ),
        .ARLEN_i   ( aplic_cfg_req.ar.len    ),
        .ARSIZE_i  ( aplic_cfg_req.ar.size   ),
        .ARBURST_i ( aplic_cfg_req.ar.burst  ),
        .ARLOCK_i  ( aplic_cfg_req.ar.lock   ),
        .ARCACHE_i ( aplic_cfg_req.ar.cache  ),
        .ARPROT_i  ( aplic_cfg_req.ar.prot   ),
        .ARREGION_i( aplic_cfg_req.ar.region ),
        .ARUSER_i  ( aplic_cfg_req.ar.user   ),
        .ARQOS_i   ( aplic_cfg_req.ar.qos    ),
        .ARVALID_i ( aplic_cfg_req.ar_valid  ),
        .ARREADY_o ( aplic_cfg_rsp.ar_ready ),
        // R
        .RID_o     ( aplic_cfg_rsp.r.id     ),
        .RDATA_o   ( aplic_cfg_rsp.r.data   ),
        .RRESP_o   ( aplic_cfg_rsp.r.resp   ),
        .RLAST_o   ( aplic_cfg_rsp.r.last   ),
        .RUSER_o   ( aplic_cfg_rsp.r.user   ),
        .RVALID_o  ( aplic_cfg_rsp.r_valid  ),
        .RREADY_i  ( aplic_cfg_req.r_ready   ),
        // APB IF
        .PENABLE   ( aplic_penable   ),
        .PWRITE    ( aplic_pwrite    ),
        .PADDR     ( aplic_paddr     ),
        .PSEL      ( aplic_psel      ),
        .PWDATA    ( aplic_pwdata    ),
        .PRDATA    ( aplic_prdata    ),
        .PREADY    ( aplic_pready    ),
        .PSLVERR   ( aplic_pslverr   )
    );

    apb_to_reg i_aplic_apb_to_reg (
        .clk_i     ( clk_i         ),
        .rst_ni    ( rst_ni        ),
        .penable_i ( aplic_penable ),
        .pwrite_i  ( aplic_pwrite  ),
        .paddr_i   ( aplic_paddr   ),
        .psel_i    ( aplic_psel    ),
        .pwdata_i  ( aplic_pwdata  ),
        .prdata_o  ( aplic_prdata  ),
        .pready_o  ( aplic_pready  ),
        .pslverr_o ( aplic_pslverr ),
        .reg_o     ( aplic_reg_bus )
    );

  `REG_BUS_TYPEDEF_ALL(aplic_reg, ariane_axi_soc::addr_t, logic[31:0], logic[3:0])
  aplic_reg_req_t aplic_regmap_req;
  aplic_reg_rsp_t aplic_regmap_resp;
  `REG_BUS_ASSIGN_TO_REQ(aplic_regmap_req, aplic_reg_bus)
  `REG_BUS_ASSIGN_FROM_RSP(aplic_reg_bus, aplic_regmap_resp)

  // MSI Bus to signal interrupts to the IMSIC
  ariane_axi_soc::req_slv_t    msi_req;
  ariane_axi_soc::resp_slv_t   msi_resp;
  `AXI_ASSIGN_TO_REQ(msi_req, imsic_master)
  `AXI_ASSIGN_FROM_RESP(imsic_master, msi_resp)

  localparam imsic_protocol_pkg::protocol_cfg_t ImsicProtocolCfg = '{
    AXI_ADDR_WIDTH: AxiAddrWidth,
    AXI_DATA_WIDTH: AxiDataWidth,
    AXI_ID_WIDTH:   AxiIdWidth
  };

  genvar i;
  generate
    for (i = 0; i < NumHarts; i++) begin
      assign irq_o[(i+1)*ariane_pkg::NrIntpFiles-1 : i*ariane_pkg::NrIntpFiles] =
        aia_csr_imsic2hart[i].Xeip_targets;
    end
  endgenerate

  aplic_top #(
    .AplicCfg       ( aplic_pkg::DefaultAplicCfg        ),
    .ImsicCfg       ( imsic_pkg::DefaultImsicCfg        ),
    .ProtocolCfg    ( ImsicProtocolCfg                  ),
    .reg_req_t      ( aplic_reg_req_t                   ),
    .reg_rsp_t      ( aplic_reg_rsp_t                   ),
    .axi_req_t      ( ariane_axi_soc::req_slv_t         ),
    .axi_resp_t     ( ariane_axi_soc::resp_slv_t        )
  ) aplic_top_embedded_i (
    .i_clk          (clk_i                              ),
    .ni_rst         ( rst_ni                            ),
    .i_irq_sources  ( {irq_sources[ariane_soc::NumSources-2:0], 1'b0}    ),
    .i_req_cfg      ( aplic_regmap_req                  ),
    .o_resp_cfg     ( aplic_regmap_resp                 ),
    .i_imsic_csr    ( aia_csr_hart2imsic                ),
    .o_imsic_csr    ( aia_csr_imsic2hart                ),         
    .i_imsic_req    ( msi_req                           ),
    .o_imsic_resp   ( msi_resp                          )
  );

endmodule // riscv_peripherals

