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
// Date: 19.03.2017
// Description: Ariane Top-level wrapper to break out SV structs to logic vectors.


module ariane_verilog_wrap
    import ariane_pkg::*;
#(
  parameter int unsigned               RASDepth              = 2,
  parameter int unsigned               BTBEntries            = 32,
  parameter int unsigned               BHTEntries            = 128,
  // debug module base address
  parameter logic [63:0]               DmBaseAddress         = 64'h0,
  // swap endianess in l15 adapter
  parameter bit                        SwapEndianess         = 1,
  // PMA configuration
  // idempotent region
  parameter int unsigned               NrNonIdempotentRules  =  1,
  parameter logic [NrMaxRules*64-1:0]  NonIdempotentAddrBase = 64'h00C0000000,
  parameter logic [NrMaxRules*64-1:0]  NonIdempotentLength   = 64'hFFFFFFFFFF,
  // executable regions
  parameter int unsigned               NrExecuteRegionRules  =  0,
  parameter logic [NrMaxRules*64-1:0]  ExecuteRegionAddrBase = '0,
  parameter logic [NrMaxRules*64-1:0]  ExecuteRegionLength   = '0,
  // cacheable regions
  parameter int unsigned               NrCachedRegionRules   =  0,
  parameter logic [NrMaxRules*64-1:0]  CachedRegionAddrBase  = '0,
  parameter logic [NrMaxRules*64-1:0]  CachedRegionLength    = '0,
  // PMP
  parameter int unsigned               NrPMPEntries          =  8
) (
  input                       clk_i,
  input                       reset_l,      // this is an openpiton-specific name, do not change (hier. paths in TB use this)
  output                      spc_grst_l,   // this is an openpiton-specific name, do not change (hier. paths in TB use this)
  // Core ID, Cluster ID and boot address are considered more or less static
  input  [riscv::VLEN-1:0]               boot_addr_i,  // reset boot address
  input  [riscv::XLEN-1:0]               hart_id_i,    // hart id in a multicore environment (reflected in a CSR)
  // IMSIC
  input   imsic_pkg::csr_channel_from_imsic_t     aia_csr_imsic2hart,
  output  imsic_pkg::csr_channel_to_imsic_t       aia_csr_hart2imsic,
  // Interrupt inputs
  input  [ariane_pkg::NrIntpFiles-1:0] irq_i, // level sensitive IR lines, mip/sip/vsip (async)
  input                       ipi_i,        // inter-processor interrupts (async)
  // Timer facilities
  input                       time_irq_i,   // timer interrupt in (async)
  input                       debug_req_i,  // debug request (async)

`ifdef PITON_ARIANE
  // L15 (memory side)
  output [$size(wt_cache_pkg::l15_req_t)-1:0]  l15_req_o,
  input  [$size(wt_cache_pkg::l15_rtrn_t)-1:0] l15_rtrn_i
`else
  // AXI (memory side)
  output [$size(ariane_axi::req_t)-1:0]             axi_req_o,
  input  [$size(ariane_axi::resp_t)-1:0]            axi_resp_i
`endif
 );

// assign bitvector to packed struct and vice versa
`ifdef PITON_ARIANE
  // L15 (memory side)
  wt_cache_pkg::l15_req_t  l15_req;
  wt_cache_pkg::l15_rtrn_t l15_rtrn;

  assign l15_req_o = l15_req;
  assign l15_rtrn  = l15_rtrn_i;

`ifdef PITON_ILA_L15
  //========================================================================
  // L1.5 request/response stall observer (debug only, PITON_ILA_L15).
  //
  // Diagnoses a hart that stops retiring instructions. If CVA6 issued a
  // request the L1.5/NoC accepted but never answered, dbg_outstanding stays
  // stops receiving returns and dbg_quiet_cnt runs away. dbg_stalled is the
  // ILA trigger; dbg_last_addr/dbg_last_rqtype name the orphaned transaction.
  //
  // One instance per tile, so every tile is observed regardless of which
  // one the stalled task happens to be scheduled on.
  //========================================================================

  // Primary liveness limit: 1 s at 50 MHz. WT_DCACHE is defined, so this
  // core is write-through -- every store reaches the L1.5. A live core
  // therefore produces L1.5 traffic on every 10 ms timer tick at the very
  // latest, even sitting in wfi. 100x that margin means dbg_stalled can
  // only assert on a core that has genuinely stopped.
  localparam logic [31:0] DbgQuietLimit = 32'd50000000;
  localparam logic [31:0] DbgCntMax     = 32'hFFFF_FFFF;

  //
  // The L1.5 link is NOT one-request-one-response. Two return types arrive
  // unsolicited, with no matching request:
  //   L15_EVICT_REQ (4'b0011)  line eviction from the L1.5
  //   L15_INT_RET   (4'b0111)  interrupt packet
  // A naive +1/-1 outstanding counter therefore drifts and wraps -- that
  // bug produced dbg_outstanding = 28/115/218/199 in the first capture.
  // Only genuine replies may decrement, and the counter saturates at both
  // ends so it can never wrap into a meaningless value again.
  //
  logic dbg_rtrn_is_reply;
  always_comb begin
    case (l15_rtrn.l15_returntype)
      wt_cache_pkg::L15_LOAD_RET,
      wt_cache_pkg::L15_ST_ACK,
      wt_cache_pkg::L15_IFILL_RET,
      wt_cache_pkg::L15_CPX_RESTYPE_ATOMIC_RES: dbg_rtrn_is_reply = 1'b1;
      default:                                  dbg_rtrn_is_reply = 1'b0;
    endcase
  end

  logic dbg_req_fire, dbg_rtrn_fire, dbg_reply_fire;
  assign dbg_req_fire   = l15_req.l15_val  & l15_rtrn.l15_ack;
  assign dbg_rtrn_fire  = l15_rtrn.l15_val & l15_req.l15_req_ack;
  assign dbg_reply_fire = dbg_rtrn_fire & dbg_rtrn_is_reply;

  // dbg_quiet_cnt is the metric that matters: cycles since ANY return.
  // No arithmetic on transaction counts, so it cannot drift.
  (* mark_debug = "true" *) logic [31:0] dbg_quiet_cnt;
  (* mark_debug = "true" *) logic [7:0]  dbg_outstanding;
  (* mark_debug = "true" *) logic [39:0] dbg_last_addr;
  (* mark_debug = "true" *) logic [$bits(wt_cache_pkg::l15_reqtypes_t)-1:0] dbg_last_rqtype;
  (* mark_debug = "true" *) logic [2:0]  dbg_last_size;
  (* mark_debug = "true" *) logic        dbg_last_nc;
  (* mark_debug = "true" *) logic [3:0]  dbg_last_rtrn;
  (* mark_debug = "true" *) logic        dbg_stalled;

  (* mark_debug = "true" *) logic        dbg_req_val;
  (* mark_debug = "true" *) logic        dbg_req_ack;
  (* mark_debug = "true" *) logic        dbg_rsp_val;
  (* mark_debug = "true" *) logic        dbg_rsp_ack;
  (* mark_debug = "true" *) logic [3:0]  dbg_rsp_type;
  (* mark_debug = "true" *) logic        dbg_l2miss;
  (* mark_debug = "true" *) logic [1:0]  dbg_rsp_err;

  assign dbg_req_val  = l15_req.l15_val;
  assign dbg_req_ack  = l15_rtrn.l15_ack;
  assign dbg_rsp_val  = l15_rtrn.l15_val;
  assign dbg_rsp_ack  = l15_req.l15_req_ack;
  assign dbg_rsp_type = l15_rtrn.l15_returntype;
  assign dbg_l2miss   = l15_rtrn.l15_l2miss;
  assign dbg_rsp_err  = l15_rtrn.l15_error;

  always_ff @(posedge clk_i or negedge reset_l) begin : p_dbg_stall
    if (~reset_l) begin
      dbg_quiet_cnt   <= '0;
      dbg_outstanding <= '0;
      dbg_stalled     <= 1'b0;
      dbg_last_addr   <= '0;
      dbg_last_rqtype <= '0;
      dbg_last_size   <= '0;
      dbg_last_nc     <= 1'b0;
      dbg_last_rtrn   <= '0;
    end else begin
      // ---- primary: cycles since ANY return from the L1.5 ----
      if (dbg_rtrn_fire)
        dbg_quiet_cnt <= '0;
      else if (dbg_quiet_cnt != DbgCntMax)   // saturate, never wrap
        dbg_quiet_cnt <= dbg_quiet_cnt + 32'd1;

      // ---- secondary: outstanding replies owed, saturating ----
      if (dbg_req_fire & ~dbg_reply_fire) begin
        if (dbg_outstanding != 8'hFF) dbg_outstanding <= dbg_outstanding + 8'd1;
      end else if (dbg_reply_fire & ~dbg_req_fire) begin
        if (dbg_outstanding != 8'h00) dbg_outstanding <= dbg_outstanding - 8'd1;
      end

      // Last transaction handed to the fabric. With a blocking core stall
      // this is the one that never came back.
      if (dbg_req_fire) begin
        dbg_last_addr   <= l15_req.l15_address;
        dbg_last_rqtype <= l15_req.l15_rqtype;
        dbg_last_size   <= l15_req.l15_size;
        dbg_last_nc     <= l15_req.l15_nc;
      end

      // Last return type seen, so a capture shows what the L1.5 last sent.
      if (dbg_rtrn_fire)
        dbg_last_rtrn <= l15_rtrn.l15_returntype;

      // Sticky: the hang is permanent, so latch it for the ILA.
      if (dbg_quiet_cnt > DbgQuietLimit)
        dbg_stalled <= 1'b1;
    end
  end
`endif // PITON_ILA_L15

`else
  ariane_axi::req_t             axi_req;
  ariane_axi::resp_t            axi_resp;

  assign axi_req_o = axi_req;
  assign axi_resp  = axi_resp_i;
`endif


  /////////////////////////////
  // Core wakeup mechanism
  /////////////////////////////

  // // this is a workaround since interrupts are not fully supported yet.
  // // the logic below catches the initial wake up interrupt that enables the cores.
  // logic wake_up_d, wake_up_q;
  // logic rst_n;

  // assign wake_up_d = wake_up_q || ((l15_rtrn.l15_returntype == wt_cache_pkg::L15_INT_RET) && l15_rtrn.l15_val);

  // always_ff @(posedge clk_i or negedge reset_l) begin : p_regs
  //   if(~reset_l) begin
  //     wake_up_q <= 0;
  //   end else begin
  //     wake_up_q <= wake_up_d;
  //   end
  // end

  // // reset gate this
  // assign rst_n = wake_up_q & reset_l;

  // this is a workaround,
  // we basically wait for 32k cycles such that the SRAMs in openpiton can initialize
  // 128KB..8K cycles
  // 256KB..16K cycles
  // etc, so this should be enough for 512k per tile

  logic [15:0] wake_up_cnt_d, wake_up_cnt_q;
  logic rst_n;

  assign wake_up_cnt_d = (wake_up_cnt_q[$high(wake_up_cnt_q)]) ? wake_up_cnt_q : wake_up_cnt_q + 1;

  always_ff @(posedge clk_i or negedge reset_l) begin : p_regs
    if(~reset_l) begin
      wake_up_cnt_q <= 0;
    end else begin
      wake_up_cnt_q <= wake_up_cnt_d;
    end
  end

  // reset gate this
  assign rst_n = wake_up_cnt_q[$high(wake_up_cnt_q)] & reset_l;


  /////////////////////////////
  // synchronizers
  /////////////////////////////

  logic [ariane_pkg::NrIntpFiles-1:0] irq;
  logic ipi, time_irq, debug_req;

  // reset synchronization
  synchronizer i_sync (
    .clk         ( clk_i      ),
    .presyncdata ( rst_n      ),
    .syncdata    ( spc_grst_l )
  );

  // interrupts
  for (genvar k=0; k<$size(irq_i); k++) begin
    synchronizer i_irq_sync (
      .clk         ( clk_i      ),
      .presyncdata ( irq_i[k]   ),
      .syncdata    ( irq[k]     )
    );
  end

  synchronizer i_ipi_sync (
    .clk         ( clk_i      ),
    .presyncdata ( ipi_i      ),
    .syncdata    ( ipi        )
  );

  synchronizer i_timer_sync (
    .clk         ( clk_i      ),
    .presyncdata ( time_irq_i ),
    .syncdata    ( time_irq   )
  );

  synchronizer i_debug_sync (
    .clk         ( clk_i       ),
    .presyncdata ( debug_req_i ),
    .syncdata    ( debug_req   )
  );

  /////////////////////////////
  // ariane instance
  /////////////////////////////

  localparam ariane_pkg::ariane_cfg_t ArianeOpenPitonCfg = '{
    RASDepth:              RASDepth,
    BTBEntries:            BTBEntries,
    BHTEntries:            BHTEntries,
    // idempotent region
    NrNonIdempotentRules:  NrNonIdempotentRules,
    NonIdempotentAddrBase: NonIdempotentAddrBase,
    NonIdempotentLength:   NonIdempotentLength,
    NrExecuteRegionRules:  NrExecuteRegionRules,
    ExecuteRegionAddrBase: ExecuteRegionAddrBase,
    ExecuteRegionLength:   ExecuteRegionLength,
    // cached region
    NrCachedRegionRules:   NrCachedRegionRules,
    CachedRegionAddrBase:  CachedRegionAddrBase,
    CachedRegionLength:    CachedRegionLength,
    // cache config
    AxiCompliant:          1'b0,
    SwapEndianess:         SwapEndianess,
    // debug
    DmBaseAddress:         DmBaseAddress,
    NrPMPEntries:          NrPMPEntries
  };

  ariane #(
    .ArianeCfg ( ArianeOpenPitonCfg )
  ) ariane (
    .clk_i       ( clk_i      ),
    .rst_ni      ( spc_grst_l ),
    .boot_addr_i              ,// constant
    .hart_id_i                ,// constant
    .imsic_csr_i  ( aia_csr_imsic2hart  ),
    .imsic_csr_o  ( aia_csr_hart2imsic  ),
    .irq_i       ( irq        ),
    .ipi_i       ( ipi        ),
    .time_irq_i  ( time_irq   ),
    .debug_req_i ( debug_req  ),
`ifdef PITON_ARIANE
    .l15_req_o   ( l15_req   ),
    .l15_rtrn_i  ( l15_rtrn  )
`else
    .axi_req_o   ( axi_req   ),
    .axi_resp_i  ( axi_resp  )
`endif
  );

endmodule // ariane_verilog_wrap
