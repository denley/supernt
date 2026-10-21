-- Simulation-only replacement for openfpga-SNES rtl/upstream/mlab.vhd (GPL-3.0): altdpram MLAB,
-- registered write, asynchronous read.
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
ENTITY mlab IS
	generic (addr_width : integer := 8; data_width : integer := 8);
	PORT (
		clock     : in  STD_LOGIC;
		rdaddress : in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		wraddress : in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		data      : in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		wren      : in  STD_LOGIC := '0';
		q         : out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs        : in  std_logic := '1'
	);
END ENTITY;
ARCHITECTURE beh OF mlab IS
	type mem_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
	signal mem : mem_t;
BEGIN
	process(clock) begin
		if rising_edge(clock) then
			if wren = '1' then
				mem(to_integer(unsigned(wraddress))) <= data;
			end if;
		end if;
	end process;
	q <= mem(to_integer(unsigned(rdaddress))) when cs = '1' else (others => '1');
END ARCHITECTURE;
