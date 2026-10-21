-- Simulation-only replacement for openfpga-SNES rtl/upstream/bram.vhd (GPL-3.0; the altsyncram
-- wrappers of srg320's MiSTer SNES core), used by quartus/snes/sim: same entity names, ports and
-- generics, behavioural RAMs that `ghdl synth` turns into Verilog memories. From
-- ~/scratch/snes-port (notes/snes-port.md), with read-during-write on the dual-port RAMs
-- changed to return new data like altsyncram's NEW_DATA_NO_NBE_READ.
-- mem_init_file is only read for MIF-initialised ROMs (DSPn, not used in the SA-1 build).
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
USE std.textio.all;
USE ieee.std_logic_textio.all;

ENTITY spram_sz IS
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		numwords      : integer := 2**8;
		mem_init_file : string := " ";
		mem_name      : string := "MEM"
	);
	PORT (
		clock   : in  STD_LOGIC;
		address : in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		data    : in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		enable  : in  STD_LOGIC := '1';
		wren    : in  STD_LOGIC := '0';
		q       : out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs      : in  std_logic := '1'
	);
END ENTITY;

ARCHITECTURE beh OF spram_sz IS
	type mem_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
	-- MIF init: reads "<mem_init_file>.hex" (one hex word per line, made by mif2hex.py),
	-- relative to the directory ghdl synth runs in.
	impure function init_mem return mem_t is
		file f : text;
		variable l : line;
		variable v : std_logic_vector(((data_width+3)/4)*4-1 downto 0);
		variable m : mem_t := (others => (others => '0'));
		variable st : file_open_status;
	begin
		if mem_init_file'length > 1 then
			file_open(st, f, mem_init_file & ".hex", read_mode);
			if st = open_ok then
				for i in 0 to numwords-1 loop
					exit when endfile(f);
					readline(f, l);
					hread(l, v);
					m(i) := v(data_width-1 downto 0);
				end loop;
				file_close(f);
			else
				report "spram_sz: cannot open " & mem_init_file & ".hex" severity failure;
			end if;
		end if;
		return m;
	end function;
	signal mem : mem_t := init_mem;
	signal q0  : std_logic_vector(data_width-1 downto 0);
BEGIN
	-- altsyncram SINGLE_PORT, NEW_DATA_NO_NBE_READ: write-through
	process(clock) begin
		if rising_edge(clock) then
			if wren = '1' and cs = '1' then
				mem(to_integer(unsigned(address))) <= data;
				q0 <= data;
			else
				q0 <= mem(to_integer(unsigned(address)));
			end if;
		end if;
	end process;
	q <= q0 when cs = '1' else (others => '1');
END ARCHITECTURE;

LIBRARY ieee;
USE ieee.std_logic_1164.all;

ENTITY spram IS
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " ";
		mem_name      : string := "MEM"
	);
	PORT (
		clock   : in  STD_LOGIC;
		address : in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		data    : in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		enable  : in  STD_LOGIC := '1';
		wren    : in  STD_LOGIC := '0';
		q       : out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs      : in  std_logic := '1'
	);
END spram;

ARCHITECTURE beh OF spram IS
BEGIN
	spram_sz : entity work.spram_sz
	generic map(addr_width, data_width, 2**addr_width, mem_init_file, mem_name)
	port map(clock,address,data,enable,wren,q,cs);
END ARCHITECTURE;

--------------------------------------------------------------
-- dpram_dif: altsyncram BIDIR_DUAL_PORT, one clock, clock enables, mixed widths
-- (ratio 1 or 2^k). Modelled as R narrow banks of 2^addr_w(wide) words.
--------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

entity dpram_dif is
	generic (
		addr_width_a  : integer := 8;
		data_width_a  : integer := 8;
		addr_width_b  : integer := 8;
		data_width_b  : integer := 8;
		mem_init_file : string := " "
	);
	PORT (
		clock			: in  STD_LOGIC;
		address_a	: in  STD_LOGIC_VECTOR (addr_width_a-1 DOWNTO 0);
		data_a		: in  STD_LOGIC_VECTOR (data_width_a-1 DOWNTO 0) := (others => '0');
		enable_a		: in  STD_LOGIC := '1';
		wren_a		: in  STD_LOGIC := '0';
		q_a			: out STD_LOGIC_VECTOR (data_width_a-1 DOWNTO 0);
		cs_a        : in  std_logic := '1';
		address_b	: in  STD_LOGIC_VECTOR (addr_width_b-1 DOWNTO 0) := (others => '0');
		data_b		: in  STD_LOGIC_VECTOR (data_width_b-1 DOWNTO 0) := (others => '0');
		enable_b		: in  STD_LOGIC := '1';
		wren_b		: in  STD_LOGIC := '0';
		q_b			: out STD_LOGIC_VECTOR (data_width_b-1 DOWNTO 0);
		cs_b        : in  std_logic := '1'
	);
end entity;

ARCHITECTURE beh OF dpram_dif IS
	signal q0 : std_logic_vector((data_width_a - 1) downto 0);
	signal q1 : std_logic_vector((data_width_b - 1) downto 0);
	signal qa_all : std_logic_vector((data_width_b - 1) downto 0);
	signal sel_r  : std_logic_vector(7 downto 0) := (others => '0');
BEGIN
	q_a <= q0 when cs_a = '1' else (others => '1');
	q_b <= q1 when cs_b = '1' else (others => '1');

	-- Same widths. altsyncram BIDIR_DUAL_PORT has two write ports; M10K in nextpnr-mistral is
	-- simple dual port only, so the two writes are merged into one write port (B has priority;
	-- in the core B only writes while A is idle, e.g. CGRAM clear during reset). Two read ports
	-- => yosys duplicates the memory (fine for the small RAMs this is used for).
	same: if data_width_a = data_width_b generate
		type mem_t is array(0 to 2**addr_width_a-1) of std_logic_vector(data_width_a-1 downto 0);
		signal mem : mem_t;
		signal wsel  : std_logic;
		signal we    : std_logic;
		signal waddr : std_logic_vector(addr_width_a-1 downto 0);
		signal wdata : std_logic_vector(data_width_a-1 downto 0);
	begin
		wsel  <= wren_b and cs_b and enable_b;
		we    <= wsel or (wren_a and cs_a and enable_a);
		waddr <= address_b when wsel = '1' else address_a;
		wdata <= data_b when wsel = '1' else data_a;
		process(clock) begin
			if rising_edge(clock) then
				if we = '1' then
					mem(to_integer(unsigned(waddr))) <= wdata;
				end if;
			end if;
		end process;
		process(clock) begin
			if rising_edge(clock) then
				if enable_a = '1' then
					if we = '1' and waddr = address_a then
						q0 <= wdata;
					else
						q0 <= mem(to_integer(unsigned(address_a)));
					end if;
				end if;
			end if;
		end process;
		process(clock) begin
			if rising_edge(clock) then
				if enable_b = '1' then
					if we = '1' and waddr = address_b then
						q1 <= wdata;
					else
						q1 <= mem(to_integer(unsigned(address_b)));
					end if;
				end if;
			end if;
		end process;
	end generate;

	-- A narrow, B wide (ratio R = 2^(addr_width_a-addr_width_b))
	a_narrow: if data_width_a < data_width_b generate
		constant R  : integer := data_width_b / data_width_a;
		constant LR : integer := addr_width_a - addr_width_b;
		constant W  : integer := data_width_a;
	begin
		banks: for i in 0 to R-1 generate
			type mem_t is array(0 to 2**addr_width_b-1) of std_logic_vector(W-1 downto 0);
			shared variable mem : mem_t;
		begin
			process(clock) begin
				if rising_edge(clock) then
					if enable_a = '1' then
						if wren_a = '1' and cs_a = '1' and to_integer(unsigned(address_a(LR-1 downto 0))) = i then
							mem(to_integer(unsigned(address_a(addr_width_a-1 downto LR)))) := data_a;
						end if;
						qa_all((i+1)*W-1 downto i*W) <= mem(to_integer(unsigned(address_a(addr_width_a-1 downto LR))));
					end if;
				end if;
			end process;
			process(clock) begin
				if rising_edge(clock) then
					if enable_b = '1' then
						if wren_b = '1' and cs_b = '1' then
							mem(to_integer(unsigned(address_b))) := data_b((i+1)*W-1 downto i*W);
						end if;
						q1((i+1)*W-1 downto i*W) <= mem(to_integer(unsigned(address_b)));
					end if;
				end if;
			end process;
		end generate;
		process(clock) begin
			if rising_edge(clock) then
				if enable_a = '1' then
					sel_r(LR-1 downto 0) <= address_a(LR-1 downto 0);
				end if;
			end if;
		end process;
		process(qa_all, sel_r)
		begin
			q0 <= qa_all(W-1 downto 0);
			for i in 0 to R-1 loop
				if to_integer(unsigned(sel_r(LR-1 downto 0))) = i then
					q0 <= qa_all((i+1)*W-1 downto i*W);
				end if;
			end loop;
		end process;
	end generate;
END ARCHITECTURE;

LIBRARY ieee;
USE ieee.std_logic_1164.all;

entity dpram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " "
	);
	PORT (
		clock			: in  STD_LOGIC;
		address_a	: in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		data_a		: in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		enable_a		: in  STD_LOGIC := '1';
		wren_a		: in  STD_LOGIC := '0';
		q_a			: out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs_a        : in  std_logic := '1';
		address_b	: in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0) := (others => '0');
		data_b		: in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		enable_b		: in  STD_LOGIC := '1';
		wren_b		: in  STD_LOGIC := '0';
		q_b			: out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs_b        : in  std_logic := '1'
	);
end entity;

ARCHITECTURE beh OF dpram IS
BEGIN
	ram : entity work.dpram_dif generic map(addr_width,data_width,addr_width,data_width,mem_init_file)
	port map(clock,address_a,data_a,enable_a,wren_a,q_a,cs_a,address_b,data_b,enable_b,wren_b,q_b,cs_b);
END ARCHITECTURE;


--------------------------------------------------------------
-- dpram_difclk: altsyncram BIDIR_DUAL_PORT with two clocks (GSU cache, CX4 data RAM use
-- clock0 = not CLK, clock1 = CLK). Modelled literally (two write ports, two clocks); only
-- used by GSU/CX4, which the SA-1-only build does not include.
--------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
entity dpram_difclk is
	generic (
		addr_width_a  : integer := 8;
		data_width_a  : integer := 8;
		addr_width_b  : integer := 8;
		data_width_b  : integer := 8;
		mem_init_file : string := " "
	);
	PORT (
		clock0		: in  STD_LOGIC;
		clock1		: in  STD_LOGIC;
		address_a	: in  STD_LOGIC_VECTOR (addr_width_a-1 DOWNTO 0);
		data_a		: in  STD_LOGIC_VECTOR (data_width_a-1 DOWNTO 0) := (others => '0');
		enable_a		: in  STD_LOGIC := '1';
		wren_a		: in  STD_LOGIC := '0';
		q_a			: out STD_LOGIC_VECTOR (data_width_a-1 DOWNTO 0);
		cs_a        : in  std_logic := '1';
		address_b	: in  STD_LOGIC_VECTOR (addr_width_b-1 DOWNTO 0) := (others => '0');
		data_b		: in  STD_LOGIC_VECTOR (data_width_b-1 DOWNTO 0) := (others => '0');
		enable_b		: in  STD_LOGIC := '1';
		wren_b		: in  STD_LOGIC := '0';
		q_b			: out STD_LOGIC_VECTOR (data_width_b-1 DOWNTO 0);
		cs_b        : in  std_logic := '1'
	);
end entity;
ARCHITECTURE beh OF dpram_difclk IS
	type mem_t is array(0 to 2**addr_width_a-1) of std_logic_vector(data_width_a-1 downto 0);
	shared variable mem : mem_t;
	signal q0 : std_logic_vector((data_width_a - 1) downto 0);
	signal q1 : std_logic_vector((data_width_b - 1) downto 0);
BEGIN
	q_a <= q0 when cs_a = '1' else (others => '1');
	q_b <= q1 when cs_b = '1' else (others => '1');
	process(clock0) begin
		if rising_edge(clock0) then
			if enable_a = '1' then
				if wren_a = '1' and cs_a = '1' then
					mem(to_integer(unsigned(address_a))) := data_a;
				end if;
				q0 <= mem(to_integer(unsigned(address_a)));
			end if;
		end if;
	end process;
	process(clock1) begin
		if rising_edge(clock1) then
			if enable_b = '1' then
				if wren_b = '1' and cs_b = '1' then
					mem(to_integer(unsigned(address_b))) := data_b;
				end if;
				q1 <= mem(to_integer(unsigned(address_b)));
			end if;
		end if;
	end process;
END ARCHITECTURE;
