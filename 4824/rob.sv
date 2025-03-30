typedef struct {
    logic [6:0]  opcode;
    logic [$clog2(NUM_REG)-1:0] dest_reg;  // dest & source register name
    logic [$clog2(NUM_REG)-1:0] src_reg1;
    logic [$clog2(NUM_REG)-1:0] src_reg2;
} instruction_t;

typedef struct {
    logic [31:0] T [NUM_REG];  
} arch_map_t;

module rob #(
    parameter NUM_ENTRIES = 7, 
    parameter NUM_REG = 4,             
    parameter PRECISE_ENTRY = 2
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        allocate_enable,
    input  logic        free_list_not_empty,
    input  logic [31:0] free_list_PR_out,
    input  logic        RS_issue_valid,
    input  logic [31:0] RS_Tout,
    input  instruction_t Insn_in,       
    input  arch_map_t   Arch_Map,
    input  logic        precise_state,
    output logic [31:0] Told_free, 
    output logic        Told_free_valid,
    output logic [31:0] ROB_Tout,
    output logic [31:0] ROB_Told,
    output logic [$clog2(NUM_REG)-1:0] ROB_REG_out,
    output logic        ROB_fetch,
    output logic        ROB_precise_state,
    output logic [31:0] ROB_PR_out,
    output logic [$clog2(NUM_REG)-1:0] ROB_REG_PR_out
);

typedef struct packed {
    instruction_t Insn;
    logic [31:0]  T;
    logic [31:0]  Told;
    logic         S;
    logic         X;
    logic         C;
} rob_entry_t;

rob_entry_t [NUM_ENTRIES-1:0] entries;
logic [$clog2(NUM_ENTRIES)-1:0] head_ptr, tail_ptr;
logic precise_state_reach;
logic raw_hazard;

// Combinational Logic
assign ROB_fetch = allocate_enable && !precise_state && !raw_hazard;  
assign ROB_Tout = entries[tail_ptr].T; 
assign ROB_Told = entries[tail_ptr].Told;
assign ROB_REG_out = entries[tail_ptr].Insn.dest_reg; 
assign ROB_precise_state = precise_state && !precise_state_reach;            
assign ROB_PR_out = entries[(head_ptr == 0) ? NUM_ENTRIES-1 : head_ptr-1].T;
assign ROB_REG_PR_out = entries[(head_ptr == 0) ? NUM_ENTRIES-1 : head_ptr-1].Insn.dest_reg;

// Sequential Logic
always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        // 1. reset logic
        foreach (entries[i]) begin
            entries[i].Insn  <= '0;
            entries[i].T     <= 0;
            entries[i].Told  <= 0;
            entries[i].S     <= 0;
            entries[i].X     <= 0;
            entries[i].C     <= 0;
        end
        head_ptr     <= 0;
        tail_ptr     <= 0;
        Told_free    <= 0;
        Told_free_valid <= 0;
	precise_state_reach <= 0;
	raw_hazard   <= 0;
    end else begin
        
        // 2. precise state logic
        if (precise_state) begin
            head_ptr <= PRECISE_ENTRY;
            // clear entry between tail and PRECISE_ENTRY, clear one entry per cycle
            if (tail_ptr != PRECISE_ENTRY) begin
                entries[tail_ptr].busy <= 0;
                entries[tail_ptr].T    <= 0;
                entries[tail_ptr].Told <= 0;
                entries[tail_ptr].S    <= 0;
                entries[tail_ptr].X    <= 0;
                entries[tail_ptr].C    <= 0;
                tail_ptr <= (tail_ptr == 0) ? NUM_ENTRIES-1 : tail_ptr-1;
		precise_state_reach <= 0;
            end
   	    else begin
		precise_state_reach <= 1;
        end 
        // 3. normal operation logic
        else begin
            if (allocate_enable) begin
                // move down tail and assign Insn
                tail_ptr <= (tail_ptr + 1) % NUM_ENTRIES;
                entries[tail_ptr].Insn <= Insn_in; 

                // assign register
                if (free_list_not_empty) begin
                    // RAW check
                    raw_hazard = 0;
                    for (int j = head_ptr; j != tail_ptr; j = (j + 1) % NUM_ENTRIES) begin
                        if (entries[j].Insn.dest_reg == entries[tail_ptr].Insn.src_reg1 ||
                            entries[j].Insn.dest_reg == entries[tail_ptr].Insn.src_reg2) begin
                            raw_hazard = 1;
                            break;
                        end
                    end
                    if (!raw_hazard) begin
                        entries[tail_ptr].T <= free_list_PR_out;
                        if (entries[tail_ptr].Insn.dest_reg < NUM_REG) begin
                            entries[tail_ptr].Told <= Arch_Map.T[entries[tail_ptr].Insn.dest_reg];
                        end else begin
                            entries[tail_ptr].Told <= 0; // register out of map table, eg. stf f2,Z(r1)
                        end
                    end
                end
            end

            // entry stage forward 
	    Told_free_valid <= 0;  // reset to 0 if later no old register released to freelist/no practical register assigned to archi_map in C stage
            // S
            if (RS_issue_valid) begin
		for (int j = head_ptr; j != tail_ptr; j = (j + 1) % NUM_ENTRIES) begin
                    if (entries[j].T == RS_Tout)) begin  // RS ready to issue
                        entries[j].S <= 1;
                    end
                end
            end
            // X
            foreach (entries[i]) begin
                if (entries[i].S) entries[i].X <= 1;
            end
            // C
            foreach (entries[i]) begin
                if (entries[i].X) entries[i].C <= 1;
                if (entries[i].C && (i == head_ptr)) begin // free Told and valdate its tag, and move down head
                    Told_free       <= entries[i].Told;
                    Told_free_valid <= 1;
		    entries[i].S    <= 0;  // this entry is completed, though head moves down, SXC tag still needs to be reset,
		    entries[i].X    <= 0;  // otherwise error can occur next time this entry is assigned
		    entries[i].C    <= 0;
                    head_ptr        <= (head_ptr + 1) % NUM_ENTRIES;
                end
            end
        end
    end
end

endmodule

