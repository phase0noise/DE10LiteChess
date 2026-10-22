# UART and browser bridge

115200 baud, 8 data bits, no parity, one stop bit; 3.3 V logic. Pico GP0 transmits
to GPIO[8] / W6; GPIO[4] / V8 transmits to Pico GP1. The UART RTL comes from the
oscilloscope example. The bridge and browser use the engine's existing command
API without the DE2 Ethernet hardware.

## Frames

All multi-byte integers are big endian. CRC is **CRC-16/CCITT-FALSE**, polynomial
0x1021, initial 0xFFFF, no reflection or final XOR. CRC covers the version byte
through the final payload byte. It excludes the two magic bytes and the CRC.

Request: `43 46 | 01 | sequence:u32 | length:u8 | payload | crc:u16`

Reply: `46 43 | 01 | sequence:u32 | status:u8 | length:u16 | payload | crc:u16`

Requests contain 1..81 payload bytes. Replies contain at most 1024. Status
0=success, 1=bad request, 2=unsupported, 3=range/busy/stale commit, 4=engine
command timeout. The first request payload byte is the chess subcommand.

The FPGA discards CRC failures and partial/framing-error packets. An incomplete
packet expires after 50 ms. The Pico waits 300 ms and retries up to three times
with the **same** sequence. The FPGA uses a fixed transport prefix plus that
sequence as the engine's 80-bit mutation token, so consecutive mutation retries
cannot execute the same command twice. One command/reply is in flight at a time;
do not pipeline requests. The engine's evaluation continues between commands.
The FPGA captures reply data before sending it over UART.

## HTTP

- `GET /`: complete embedded webpage, including artwork and scripts.
- `GET /api/info`: bridge metadata and age of the latest UART reply.
- `POST /api/command`: ASCII hex encoding of 1..81 command bytes, with a
  Content-Length header. Example body `00` requests engine status.

Successful bridge exchange: `{"status":0,"payload":"53434631..."}`. The status
is the engine status even when it is nonzero. UART timeout returns HTTP 504
and an error string. Request body limit is 162 bytes and header limit is 1024.
The service handles one connection at a time and closes every response.

## Engine commands

| Subcommand | Request bytes after subcommand | Success payload |
| --- | --- | --- |
| 0 | none | 32-byte status |
| 1 | 64 piece bytes, turn, rights, EP | zero acknowledgement |
| 2 | none | start evaluation acknowledgement |
| 3 | none | stop acknowledgement |
| 4 | none | 16 attack-map bytes + 64 signed field bytes |
| 5 | none | 67-byte factual position |
| 6 | none | 80 configuration bytes |
| 7 | candidate page 0..15 | 16 records: move:u16, score:i16 |
| 8 | 80 configuration bytes | acknowledgement |
| 9 | PRNG seed:u32 | acknowledgement |
| 10 | none | reset position acknowledgement |
| 11 | position generation:u32, selected move:u16 | guarded commit acknowledgement |
| 12 | policy page 0..1 | 64 policy bytes |
| 13 | policy page 0..1, 64 bytes | policy upload acknowledgement |
| 14 | explanation page 0..63 | four 18-byte records |
| 17 | count 0..8, newest-first move:u16 values | history acknowledgement |
| 18 | none | nodes:u32, cutoffs:u32, depth:u8, quiescence:u8 |

Position squares run a1=0 to h8=63. Piece types: 1 pawn, 2 knight, 3 bishop,
4 rook, 5 queen, 6 king; bit 3 marks black. Empty=0. Turn=0 white / 1 black.
Rights bits: WK, WQ, BK, BQ. EP=64 means none. Move bits: source [5:0],
destination [11:6], promotion kind [14:12]. Attack maps use little-endian
64-bit square bitsets; other multi-byte fields are big endian.

Status: bytes 0..3 `SCF1`, 4 busy, 5 done, 6 check, 7 turn, 8..9 legal count,
10..11 best move, 12..13 signed score, 14 FSM, 15 engine protocol version (3),
16..19 decision cycles at 50 MHz, 20..23 position generation. Remaining fields
contain PRNG/field/history diagnostics. A completed, idle status validates the
selected move. Commit requires its matching generation and move. Browser
verification compares the complete candidate set and pre/post-commit positions
before updating its game with an FPGA reply.
