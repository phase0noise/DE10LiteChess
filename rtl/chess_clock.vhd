library ieee;
use ieee.std_logic_1164.all;

entity chess_clock is
  generic(MULTIPLY_BY : positive := 3; DIVIDE_BY : positive := 2);
  port(reference,reset : in std_logic; clock_out,locked : out std_logic);
end;
architecture rtl of chess_clock is
  -- Declare the logical ALTPLL interface only. Importing the full simulation
  -- component forwards zero-valued physical counter defaults into synthesis.
  component altpll is
    generic(intended_device_family : string; inclk0_input_frequency : natural;
      operation_mode,compensate_clock,bandwidth_type : string;
      clk0_multiply_by,clk0_divide_by,width_clock : natural;
      port_inclk0,port_inclk1,port_areset,port_locked,port_clk0,lpm_type : string);
    port(inclk : in std_logic_vector(1 downto 0); areset : in std_logic;
      clk : out std_logic_vector(width_clock-1 downto 0); locked : out std_logic);
  end component;
  signal clocks : std_logic_vector(4 downto 0);
begin
  clocking : altpll
    generic map(intended_device_family=>"MAX 10",inclk0_input_frequency=>20000,
      operation_mode=>"NORMAL",compensate_clock=>"CLK0",bandwidth_type=>"AUTO",
      clk0_multiply_by=>MULTIPLY_BY,clk0_divide_by=>DIVIDE_BY,width_clock=>5,
      port_inclk0=>"PORT_USED",port_inclk1=>"PORT_UNUSED",port_areset=>"PORT_USED",
      port_locked=>"PORT_USED",port_clk0=>"PORT_USED",lpm_type=>"altpll")
    port map(inclk=>('0'&reference),areset=>reset,clk=>clocks,locked=>locked);
  clock_out<=clocks(0);
end;
