-- Synchronous MAX 10 block RAM: ordered moves, transpositions, quiet history
-- and a constant Zobrist ROM. No RAM contents are reset through logic.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity chess_search_memory is
  port(clk : in std_logic;
    queue_we : in std_logic;
    queue_write_address,queue_read_address : in natural range 0 to SEARCH_LEVELS*SEARCH_MOVES-1;
    queue_write_data : in std_logic_vector(31 downto 0);
    queue_data : out std_logic_vector(31 downto 0);
    cache_we : in std_logic;
    cache_write_address,cache_read_address : in natural range 0 to CACHE_ENTRIES-1;
    cache_write_data : in std_logic_vector(127 downto 0);
    cache_data : out std_logic_vector(127 downto 0);
    history_we : in std_logic;
    history_write_address,history_read_address : in natural range 0 to 4095;
    history_write_data : in unsigned(12 downto 0);
    history_data : out unsigned(12 downto 0);
    hash_piece : in piece_t; hash_square : in natural range 0 to 63;
    hash_data : out hash_t);
end;

architecture ram of chess_search_memory is
  type queue_ram_t is array(0 to SEARCH_LEVELS*SEARCH_MOVES-1) of std_logic_vector(31 downto 0);
  type cache_ram_t is array(0 to CACHE_ENTRIES-1) of std_logic_vector(127 downto 0);
  type history_ram_t is array(0 to 4095) of unsigned(12 downto 0);
  type hash_rom_t is array(0 to 1023) of hash_t;
  function make_hash_rom return hash_rom_t is
    variable result : hash_rom_t;
    variable seed,z : hash_t := x"6A09E667F3BCC909";
  begin
    for i in result'range loop
      -- SplitMix64 is evaluated at elaboration, not synthesized as multipliers.
      seed:=seed+x"9E3779B97F4A7C15";
      z:=resize((seed xor shift_right(seed,30))*unsigned'(x"BF58476D1CE4E5B9"),64);
      z:=resize((z xor shift_right(z,27))*unsigned'(x"94D049BB133111EB"),64);
      result(i):=z xor shift_right(z,31);
      if i/64=0 then result(i):=(others=>'0'); end if;
    end loop;
    return result;
  end;
  signal moves : queue_ram_t;
  signal cache : cache_ram_t := (others=>(others=>'0'));
  signal history : history_ram_t := (others=>(others=>'0'));
  signal hashes : hash_rom_t := make_hash_rom;
  attribute ramstyle : string;
  attribute ramstyle of moves,cache,history,hashes : signal is "M9K, no_rw_check";
  attribute romstyle : string;
  attribute romstyle of hashes : signal is "M9K";
begin
  process(clk) begin
    if rising_edge(clk) then
      queue_data<=moves(queue_read_address);
      if queue_we='1' then moves(queue_write_address)<=queue_write_data; end if;
      cache_data<=cache(cache_read_address);
      if cache_we='1' then cache(cache_write_address)<=cache_write_data; end if;
      history_data<=history(history_read_address);
      if history_we='1' then history(history_write_address)<=history_write_data; end if;
      hash_data<=hashes(to_integer(unsigned(hash_piece))*64+hash_square);
    end if;
  end process;
end;
