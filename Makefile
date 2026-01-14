PROJECT = ruskcore
FILELIST = $(PROJECT).f

TOP_MODULE = top
TB_PROGRAM = src/tb_verilator.cpp
OBJ_DIR = obj_dir/
SIM_NAME = sim
VERILATOR_FLAGS = ""

.PHONY: build
build:
	veryl fmt
	veryl build

.PHONY: clean
clean:
	veryl clean
	rm -rf $(OBJ_DIR)

.PHONY: sim
sim:
		verilator --cc $(VERILATOR_FLAGS) -f $(FILELIST) --exe $(TB_PROGRAM) --top-module $(PROJECT)_$(TOP_MODULE) --Mdir $(OBJ_DIR) -CFLAGS "-std=c++17"
		make -C $(OBJ_DIR) -f V$(PROJECT)_$(TOP_MODULE).mk
		mv $(OBJ_DIR)/V$(PROJECT)_$(TOP_MODULE) $(OBJ_DIR)/$(SIM_NAME)
