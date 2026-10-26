/*
  ORBT's entry point into one flavour of Stockfish, compiled once per flavour with
  OT_SF_MAIN naming the C function and sfio_config.h naming the engine's namespace.

  It mirrors upstream's src/main.cpp (and lichess's multistockfish shim) except that the
  engine reads and writes the descriptors it is given instead of stdin and stdout, so the
  app's own streams are untouched and two flavours can be linked into one binary.

  Copyright (C) 2026 ORBT contributors; Stockfish (C) the Stockfish developers.
  GPL-3.0-or-later, see ../vendor/stockfish/Copying.txt.
*/

#include <utility>

#include "attacks.h"
#include "bitboard.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

#include "sfio.h"

// Runs the engine's UCI loop on the calling thread until it reads "quit" or the end of its
// input. Returns 0, or -1 if the descriptors cannot be used.
extern "C" int OT_SF_MAIN(int read_fd, int write_fd) {
    using namespace SFIO_NAMESPACE;

    if (!sfio::bind(read_fd, write_fd))
        return -1;

    sfio::out() << engine_info() << std::endl;

    Attacks::init();
    Position::init();

    char  name[] = "stockfish";
    char* argv[] = {name, nullptr};
    auto  cli    = CommandLine(1, argv);
    {
        UCIEngine uci(std::move(cli));
        Tune::init(uci.engine_options());
        uci.loop();
    }
    sfio::out() << std::flush;
    return 0;
}
