/*
  ORBT's entry point into one flavour of Stockfish, compiled once per flavour with
  ORBT_SF_MAIN naming the C function and sfio_config.h naming the engine's namespace.
  On Android's arm64 a flavour's dot product copy also defines ORBT_SF_INIT, the section
  build.rs moved its static initializers to (see dotprod_copy there).

  It mirrors upstream's src/main.cpp (and lichess's multistockfish shim) except that the
  engine reads and writes the descriptors it is given instead of stdin and stdout, so the
  app's own streams are untouched and two flavours can be linked into one binary.

  Copyright (C) 2026 ORBT contributors; Stockfish (C) the Stockfish developers.
  GPL-3.0-or-later, see ../vendor/stockfish/Copying.txt.
*/

#include <cstdint>
#include <mutex>
#include <utility>

#ifdef _WIN32
    #include <fcntl.h>
    #include <io.h>
    #include <windows.h>
#endif

#include "attacks.h"
#include "bitboard.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

#include "sfio.h"

#ifdef ORBT_SF_INIT
    #define ORBT_SF_CAT2(a, b) a##b
    #define ORBT_SF_CAT(a, b) ORBT_SF_CAT2(a, b)
    #define ORBT_SF_INIT_START ORBT_SF_CAT(__start_, ORBT_SF_INIT)
    #define ORBT_SF_INIT_STOP ORBT_SF_CAT(__stop_, ORBT_SF_INIT)

// The linker's bounds of the section that holds this copy's static initializers (hidden: they
// are no one else's business).
extern "C" __attribute__((visibility("hidden"))) void (*ORBT_SF_INIT_START[])(void);
extern "C" __attribute__((visibility("hidden"))) void (*ORBT_SF_INIT_STOP[])(void);

// Runs them once, in order, as the loader would have (upstream's entry_arm64.cpp).
static void run_static_initializers() {
    static std::once_flag once;
    std::call_once(once, [] {
        for (auto init = ORBT_SF_INIT_START; init != ORBT_SF_INIT_STOP; ++init)
            (*init)();
    });
}
#endif

// Runs the engine's UCI loop on the calling thread until it reads "quit" or the end of its
// input. Returns 0, or -1 if the descriptors cannot be used.
static int orbt_sf_run(int read_fd, int write_fd) {
    using namespace SFIO_NAMESPACE;

#ifdef ORBT_SF_INIT
    run_static_initializers();
#endif

    if (!sfio::bind(read_fd, write_fd))
        return -1;

    sfio::out() << engine_info() << std::endl;

    Attacks::init();
    Position::init();

    char  name[] = "stockfish";
    char* argv[] = {name, nullptr};
    auto  cli    = CommandLine(1, argv);
    // On Windows the constructor reads the host process's own command line instead (the app's,
    // or java's with all its arguments), which the UCI loop would run as a one-shot command and
    // then quit. This engine has no command line.
    cli.argc = 1;
    cli.argv = argv;
    {
        UCIEngine uci(std::move(cli));
        Tune::init(uci.engine_options());
        uci.loop();
    }
    sfio::out() << std::flush;
    return 0;
}

#ifdef _WIN32
// Windows hands over the two pipe handles (orbt-engine's lib.rs): this C runtime opens its own
// descriptors on them, so they are the ones the engine's read() and write() know, and closes
// them (and so the handles) when the loop returns.
extern "C" int ORBT_SF_MAIN(intptr_t read_handle, intptr_t write_handle) {
    const int read_fd = _open_osfhandle(read_handle, _O_RDONLY | _O_BINARY);
    if (read_fd == -1)
    {
        CloseHandle(reinterpret_cast<HANDLE>(read_handle));
        CloseHandle(reinterpret_cast<HANDLE>(write_handle));
        return -1;
    }
    const int write_fd = _open_osfhandle(write_handle, _O_WRONLY | _O_BINARY);
    if (write_fd == -1)
    {
        _close(read_fd);
        CloseHandle(reinterpret_cast<HANDLE>(write_handle));
        return -1;
    }
    const int result = orbt_sf_run(read_fd, write_fd);
    _close(read_fd);
    _close(write_fd);
    return result;
}
#else
extern "C" int ORBT_SF_MAIN(int read_fd, int write_fd) { return orbt_sf_run(read_fd, write_fd); }
#endif
