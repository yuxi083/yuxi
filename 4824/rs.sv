module rs #(
    parameter NUM_ENTRIES = 7,    
    parameter NUM_REG = 4         
)(
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] free_list_PR_out,
    input  logic        free_list_not_empty,
    input  logic        ROB_fetch,
    input  instruction_t instruction_in,
    input  logic [31:0] CDB_tag,
    input  logic        CDB_valid,
    input  logic        ROB_precise_state,
    input  reg_entry_t [$clog2(NUM_REG)-1:0] reg_map,
    output OPERATION    operation_out,
    output logic        RS_issue_valid
);

typedef struct packed {
    logic [31:0] T;
    logic        valid;
} reg_entry_t;

typedef struct {
    logic [6:0]  op;
    logic [31:0] T1;
    logic [31:0] T2;
    logic [31:0] T;
} OPERATION;

typedef struct {
    logic [6:0]  opcode;
    logic [$clog2(NUM_REG)-1:0] dest_reg;
    logic [$clog2(NUM_REG)-1:0] src_reg1;
    logic [$clog2(NUM_REG)-1:0] src_reg2;
} instruction_t;

typedef struct packed {
    OPERATION operation;
    logic     busy;
    logic     T1_valid;
    logic     T2_valid;
} rs_entry_t;

rs_entry_t [NUM_ENTRIES-1:0] entries;

always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        foreach(entries[i]) begin
            entries[i] <= '{
                operation: '{op:0, T1:0, T2:0, T:0},
                busy: 0,
                T1_valid: 0,
                T2_valid: 0
            };
        end
        issue_ptr <= 0;
    end else begin
        // 1. precise state logic
        if (ROB_precise_state) begin
            // find the most recent busy entry and clear it
            for (int i=NUM_ENTRIES-1; i>=0; i--) begin
                if (entries[i].busy) begin
                    entries[i].busy <= 0;
                    break;  // clear 1 entry at most per cycle
                end
            end
        end 
        else begin
            // 2. entry assign logic
            if (ROB_fetch && free_list_not_empty) begin
                foreach(entries[i]) begin
                    if (!entries[i].busy) begin
                        entries[i].busy <= 1;
                        entries[i].operation.op <= instruction_in.opcode;
                        entries[i].operation.T <= free_list_PR_out;
                        
                        if (instruction_in.src_reg1 < NUM_REG) begin // src_reg can be found in map table
                            entries[i].operation.T1 <= reg_map[instruction_in.src_reg1].T;
                            entries[i].T1_valid <= reg_map[instruction_in.src_reg1].valid);
                        end else begin  // register out of map table, eg. stf f2,Z(r1)
                            entries[i].operation.T1 <= 0;
                            entries[i].T1_valid <= 1;
                        end
                        if (instruction_in.src_reg2 < NUM_REG) begin
                            entries[i].operation.T2 <= reg_map[instruction_in.src_reg2].T;
                            entries[i].T2_valid <= reg_map[instruction_in.src_reg2].valid);
                        end else begin
                            entries[i].operation.T2 <= 0;
                            entries[i].T2_valid <= 1; 
                        end
                        break;
                    end
                end
            end
            // 3. CDB broadcast logic
            if (CDB_valid) begin
                foreach(entries[i]) begin
                    if (entries[i].busy) begin
                        if (entries[i].operation.T1 == CDB_tag) 
                            entries[i].T1_valid <= 1;
                        if (entries[i].operation.T2 == CDB_tag)
                            entries[i].T2_valid <= 1;
                    end
                end
            end
            // 4. issue ready, free the entry in next cycle
 	    for (int i=0; i<NUM_ENTRIES; i++) begin
                if (rs_entries[i].busy && rs_entries[i].T1_valid && rs_entries[i].T2_valid) begin
		    entries[i] <= '{
                	operation: '{op:0, T1:0, T2:0, T:0},
                	busy: 0,
                	T1_valid: 0,
                	T2_valid: 0
            	    };
		    break;  // Should only issue one entry at a time
                end
            end
        end
    end
end

// Use CL here because when CDB broadcasts, Issue stage should get the valid signal in the same cycle
always_comb begin  
    operation_out = '{default:0};
    RS_issue_valid = 0;
    if (!reset) begin
        for (int i=0; i<NUM_ENTRIES; i++) begin
            if (entries[i].busy && entries[i].T1_valid && entries[i].T2_valid) begin
                operation_out = entries[i].operation;
                RS_issue_valid = 1;  
                break;  // At a time only one entry should be taken as the module output.
            end else begin
		RS_issue_valid = 0;
	    end
        end
    end
end

endmodule
