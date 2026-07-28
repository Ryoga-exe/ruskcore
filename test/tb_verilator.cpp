#include <_stdlib.h>
#include <verilated.h>

#include <cstddef>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>

#include "Vruskcore_top.h"

namespace fs = std::filesystem;
extern "C" const char* get_env_value(const char* key) {
    const char* value = getenv(key);
    if (value == nullptr) return "";
    return value;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 3) {
        std::cout << "Usage: " << argv[0] << "ROM_FILE_PATH RAM_FILE_PATH [CYCLE]" << std::endl;
        return 1;
    }

    // メモリの初期値を格納しているファイル名
    std::string rom_file_path = argv[1];
    std::string ram_file_path = argv[2];
    try {
        // 絶対パスに変換する
        rom_file_path = fs::absolute(rom_file_path).string();
        ram_file_path = fs::absolute(ram_file_path).string();
    } catch (const std::exception& e) {
        std::cerr << "Invalid memory file path : " << e.what() << std::endl;
        return 1;
    }

    // シミュレーションを実行するクロックサイクル数
    unsigned long long cycles = 0;
    if (argc >= 4) {
        std::string cycles_string = argv[3];
        try {
            cycles = stoull(cycles_string);
        } catch (const std::exception& e) {
            std::cerr << "Invalid number: " << argv[3] << std::endl;
            return 1;
        }
    }

    // 環境変数でメモリの初期化用ファイルを指定する
    const char* original_env_rom = getenv("ROM_FILE_PATH");
    const char* original_env_ram = getenv("RAM_FILE_PATH");
    setenv("ROM_FILE_PATH", rom_file_path.c_str(), 1);
    setenv("RAM_FILE_PATH", ram_file_path.c_str(), 1);

    // top
    Vruskcore_top* dut = new Vruskcore_top();

    // reset
    dut->clk = 0;
    dut->rst = 1;
    dut->eval();
    dut->rst = 0;
    dut->eval();

    // 環境変数を元に戻す
    if (original_env_rom != nullptr) {
        setenv("ROM_FILE_PATH", original_env_rom, 1);
    }
    if (original_env_ram != nullptr) {
        setenv("RAM_FILE_PATH", original_env_ram, 1);
    }

    // loop
    dut->rst = 1;
    for (long long i = 0; !Verilated::gotFinish() && (cycles == 0 || i / 2 < cycles); i++) {
        dut->clk = !dut->clk;
        dut->eval();
    }

    dut->final();

#ifdef TEST_MODE
    return dut->test_success != 1;
#endif
}
