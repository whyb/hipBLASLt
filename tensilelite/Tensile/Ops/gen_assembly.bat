@echo off
setlocal EnableDelayedExpansion

:: 参数：%1 架构字符串（以分号分隔），%2 目标目录，%3 虚拟环境目录，%4 build_id_kind
set "archStr=%~1"
set "dst=%~2"
set "venv=%~3"
set "build_id_kind=%~4"

:: 设置 ROCm 安装目录（默认为 D:\AMD\ROCm\6.2），可通过环境变量 ROCM_PATH 覆盖
set "rocm_path=D:\AMD\ROCm\6.2"
if defined ROCM_PATH (
    set "rocm_path=%ROCM_PATH%"
)

:: 设置 toolchain 路径（注意：此处按照题目要求使用 rocm_path\bin\clang++.exe）
set "toolchain=%rocm_path%\bin\clang++.exe"

:: 激活虚拟环境（Windows 下虚拟环境通常在 Scripts 目录下）
call "%venv%\Scripts\activate"

:: 将 archStr 中的分号替换为空格，得到一个空格分隔的架构列表
set "archs=%archStr:;= %"

for %%a in (%archs%) do (
    set "arch=%%a"
    echo Creating code object for arch !arch!
    set "objs="

    rem === 第一组：LayerNormGenerator（对应 "256 4 1" 和 "256 4 0"）===
    for %%I in ("256 4 1" "256 4 0") do (
        rem 用 echo 和 for /f 分解字符串为三个部分（w、c、sweep）
        for /f "tokens=1-3" %%b in ('echo %%~I') do (
            set "w=%%b"
            set "c=%%c"
            set "sweep=%%d"
            set "s=%dst%\L_!w!_!c!_!sweep!_!arch!.s"
            set "o=%dst%\L_!w!_!c!_!sweep!_!arch!.o"
            python3 LayerNormGenerator.py -o "!s!" -w !w! -c !c! --sweep-once !sweep! --arch !arch! --toolchain "%toolchain%"
            set "objs=!objs! !o!"
        )
    )

    rem === 第二组：SoftmaxGenerator（对应 "16 16" "8 32" "4 64" "2 128" "1 256"）===
    for %%I in ("16 16" "8 32" "4 64" "2 128" "1 256") do (
        for /f "tokens=1,2" %%b in ('echo %%~I') do (
            set "m=%%b"
            set "n=%%c"
            set "s=%dst%\S_!m!_!n!_!arch!.s"
            set "o=%dst%\S_!m!_!n!_!arch!.o"
            python3 SoftmaxGenerator.py -o "!s!" -m !m! -n !n! --arch !arch! --toolchain "%toolchain%"
            set "objs=!objs! !o!"
        )
    )

    rem === 第三组：AMaxGenerator（对应 "S S 256 4" "H H 256 4" "H S 256 4" "S H 256 4"）===
    for %%I in ("S S 256 4" "H H 256 4" "H S 256 4" "S H 256 4") do (
        for /f "tokens=1-4" %%b in ('echo %%~I') do (
            set "p1=%%b"
            set "p2=%%c"
            set "p3=%%d"
            set "p4=%%e"
            set "s=%dst%\A_!p1!_!p2!_!p3!_!p4!_!arch!.s"
            set "o=%dst%\A_!p1!_!p2!_!p3!_!p4!_!arch!.o"
            python3 AMaxGenerator.py -o "!s!" -t !p1! -d !p2! -w !p3! -c !p4! --arch !arch! --toolchain "%toolchain%"
            set "objs=!objs! !o!"
        )
    )

    rem === 针对符合 gfx94[0-9] 的架构，额外进行 AMaxGenerator（对应 "S S F8 256 4" "S S B8 256 4" "S H F8 256 4" "S H B8 256 4"）===
    rem 此处采用判断架构前5字符是否为 "gfx94"（不区分大小写）
    if /I "!arch:~0,5!"=="gfx94" (
        for %%I in ("S S F8 256 4" "S S B8 256 4" "S H F8 256 4" "S H B8 256 4") do (
            for /f "tokens=1-5" %%b in ('echo %%~I') do (
                set "p1=%%b"
                set "p2=%%c"
                set "p3=%%d"
                set "p4=%%e"
                set "p5=%%f"
                set "s=%dst%\A_!p1!_!p2!_!p3!_!p4!_!p5!_!arch!.s"
                set "o=%dst%\A_!p1!_!p2!_!p3!_!p4!_!p5!_!arch!.o"
                python3 AMaxGenerator.py --is-scale -o "!s!" -t !p1! -d !p2! -s !p3! -w !p4! -c !p5! --arch !arch! --toolchain "%toolchain%"
                set "objs=!objs! !o!"
            )
        )
    )

    rem === 链接所有生成的目标文件并创建 ExtOp 库 ===
    "%toolchain%" -target amdgcn-amdhsa -Xlinker --build-id=%build_id_kind% -o %dst%\extop_!arch!.co !objs!
    python3 ExtOpCreateLibrary.py --src=%dst% --co=%dst%\extop_!arch!.co --output=%dst% --arch !arch!
)

:: 退出虚拟环境
call deactivate

endlocal
