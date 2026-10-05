Gyrinus II: a fourth game, analysed cold
========================================

Gyrinus II - Son of Gyrinus (Tom Cooper, 1991, public domain). The
recompilation is ~/games/gyrinus-ii (README.md there); its
tools/images.py runs `superspider s1b` and phase6/ss_to_spider.py on
every image:

    image                             base       code words  functions  data  unresolved  problems
    Code.MCode (the game)             &7F800          8217         50   307           0         0
    16 sample voice modules           RMA, each   121 or 126        10     2           0         0
    CoconizerSong music player        &1840000          423        22    25           0         0

What was new
------------

1. An absolute file not entered at its load address. MCode loads at
   &7F800 and its execution address is &8BD08, near its end; everything
   before that is data and code it calls. `--exec ADDR` makes that the
   entry point instead of BASE. Without it, BASE was taken as a function:
   the graphics at &7F800 decoded into 2 problems ("call outside image",
   "undefined").
2. Modules with no SWIs and no commands, only init/final entries: the
   voices install a voice generator (Sound_InstallVoice block, `Riscos.Entries`
   from Twin World point 6), the music player claims EventV in its init.
   Both came out complete from the module header entries and address-taken
   pass, with no hand-given entries.

Nothing in SuperSpider's analysis had to change apart from (1). In
play-testing (title, the hub zone, entering a zone, randomised play, Escape
back to the title, quitting) nothing was interpreted and --trace-gaps logged
no gaps.

The six music modules (title tune and one per level) share the player's
code: their code and data words, as classified, differ in one data word
(song parameters, read at run time), so one translation serves all six at a
shared RMA address.
