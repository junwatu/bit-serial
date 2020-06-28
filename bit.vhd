-- File:        bit.vhd
-- Author:      Richard James Howe
-- Repository:  https://github.com/howerj/bit-serial
-- License:     MIT
-- Description: An N-bit, simple and small bit serial CPU

library ieee, work, std;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all; -- for debug only, not needed for synthesis

-- The bit-serial CPU itself, the interface is bit-serial as well as the
-- CPU itself, address and data are N bits wide. The enable lines are held
-- high for N cycles when data is clocked in or out, and a complete read or
-- write consists of N cycles (although those cycles may not be contiguous,
-- it is up to the BCPU). The three enable lines are mutually exclusive,
-- only one will be active at any time.
--
-- There are a few configurable items, but the defaults should work fine.
entity bcpu is 
	generic (
		asynchronous_reset: boolean    := true;   -- use asynchronous reset if true, synchronous if false
		delay:              time       := 0 ns;   -- simulation only, gate delay
		N:                  positive   := 16;     -- size the CPU, minimum is 8
		parity:             std_ulogic := '0';    -- set parity (even/odd) of parity flag
		jumpz:              std_ulogic := '1';    -- jump on zero = '1', jump on non-zero = '0'
		indirection:        boolean    := true;   -- if true, indirection is on instruction is turned on.
		debug:              natural    := 0);     -- debug level, 0 = off
	port (
		clk, rst:       in std_ulogic;
		i:              in std_ulogic;
		o, a:          out std_ulogic;
		oe, ie, ae: buffer std_ulogic;
		stop:          out std_ulogic);
end;

architecture rtl of bcpu is
	type state_t is (RESET, FETCH, INDIRECT, OPERAND, EXECUTE, STORE, LOAD, ADVANCE, HALT);
	type cmd_t is (
		iOR,     iAND,    iXOR,     iADD,
		iLSHIFT, iRSHIFT, iLOAD,    iSTORE,
		iLOADC,  iSTOREC, iLITERAL, iUNUSED,
		iJUMP,   iJUMPZ,  iSET,     iGET);

	constant Cy:  integer :=  0; -- Carry; set by addition
	constant Z:   integer :=  1; -- Accumulator is zero
	constant Ng:  integer :=  2; -- Accumulator is negative
	constant PAR: integer :=  3; -- Parity of accumulator
	constant ROT: integer :=  4; -- Use rotate instead of shift
	constant R:   integer :=  5; -- Reset CPU
	constant IND: integer :=  6; -- Indirect
	constant HLT: integer :=  7; -- Halt CPU

	type registers_t is record
		state:  state_t;    -- state machine register
		choice: state_t;    -- computed next state
		first:  boolean;    -- First flag, for setting up an instruction
		last4:  boolean;    -- Are we processing the last 4 bits of the instruction?
		is_io:  boolean;    -- is get/set an I/O operation?
		indir:  boolean;    -- does the instruction require indirection of the operand?
		tcarry: std_ulogic; -- temporary carry flag
		dline:  std_ulogic_vector(N - 1 downto 0); -- delay line, 16 cycles, our timer
		acc:    std_ulogic_vector(N - 1 downto 0); -- accumulator
		pc:     std_ulogic_vector(N - 1 downto 0); -- program counter
		op:     std_ulogic_vector(N - 1 downto 0); -- operand to instruction
		flags:  std_ulogic_vector(N - 1 downto 0); -- flags register
		cmd:    std_ulogic_vector(3 downto 0);     -- instruction
	end record;

	constant registers_default: registers_t := (
		state  => RESET,
		choice => RESET,
		first  => true,
		last4  => false,
		is_io  => false,
		indir  => false,
		tcarry => 'X',
		dline  => (others => '0'),
		acc    => (others => 'X'),
		pc     => (others => 'X'),
		op     => (others => 'X'),
		flags  => (others => 'X'),
		cmd    => (others => 'X'));

	signal c, f: registers_t := registers_default; -- BCPU registers, all of them.
	signal cmd: cmd_t; -- Shows up nicely in traces as an enumerated value
	signal add1, add2, acin, ares, acout: std_ulogic; -- shared adder signals
	signal last4, last:                   std_ulogic; -- state sequence signals

	-- 'adder' implements a full adder, which is all we need to implement
	-- N-bit addition in a bit serial architecture.
	procedure adder (x, y, cin: in std_ulogic; signal sum, cout: out std_ulogic) is
	begin
		sum  <= x xor y xor cin after delay;
		cout <= (x and y) or (cin and (x xor y)) after delay;
	end procedure;

	-- 'bit_count' is used for assertions and nothing else. It counts the
	-- number of bits in a 'std_ulogic_vector'.
	function bit_count(bc: in std_ulogic_vector) return natural is 
		variable count: natural := 0;
	begin
		for index in bc'range loop
			if bc(index) = '1' then
				count := count + 1;
			end if;
		end loop;
		return count;
	end function;

	-- Obviously this does not synthesis, which is why synthesis is turned
	-- off for the body of this function, it does make debugging much easier
	-- though, we will be able to which instructions are executed and do so
	-- by name. Hexadecimal would have been better than decimal, but we cannot
	-- have everything.
	procedure print_debug_info is 
		function stringify(slv: in std_ulogic_vector) return string is
		begin
			return integer'image(to_integer(unsigned(slv)));
		end function;
		variable ll: line;
	begin
		-- synthesis translate_off
		if debug > 0 then
			if c.state = EXECUTE and c.first then
				write(ll, stringify(c.pc)    & ": ");
				write(ll, cmd_t'image(cmd)   & " ");
				write(ll, stringify(c.acc)   & " ");
				write(ll, stringify(c.op)    & " ");
				write(ll, stringify(c.flags) & " ");
				writeline(OUTPUT, ll);
			end if;
			if debug > 1 and last = '1' then
				write(ll, state_t'image(c.state) & " => ");
				write(ll, state_t'image(f.state));
				writeline(OUTPUT, ll);
			end if;
		end if;
		-- synthesis translate_on
	end procedure;
begin
	assert N >= 8                      report "CPU Width too small: N >= 8"   severity failure;
	assert not (ie = '1' and oe = '1') report "input/output at the same time" severity failure;
	assert not (ie = '1' and ae = '1') report "input whilst changing address" severity failure;
	assert not (oe = '1' and ae = '1') report "output whilst changing address" severity failure;

	adder (add1, add2, acin, ares, acout);                 -- shared adder
	cmd         <= cmd_t'val(to_integer(unsigned(c.cmd))); -- used for debug purposes
	last4       <= c.dline(c.dline'high - 4) after delay;  -- processing last four bits?
	last        <= c.dline(c.dline'high)     after delay;  -- processing last bit?

	process (clk, rst) begin
		if rst = '1' and asynchronous_reset then
			c.dline <= (others => '0') after delay; -- parallel reset!
			c.state <= RESET after delay;
		elsif rising_edge(clk) then
			c <= f after delay;
			if rst = '1' and not asynchronous_reset then
				c.dline <= (others => '0') after delay;
				c.state <= RESET after delay;
			else
				-- These are just assertions, they are not required for running, but
				-- we can make sure there are no unexpected state transitions, and
				-- report on the internal state.
				print_debug_info;
				if c.state = RESET   and last = '1' then assert f.state = FETCH;   end if;
				if c.state = LOAD    and last = '1' then assert f.state = ADVANCE; end if;
				if c.state = STORE   and last = '1' then assert f.state = ADVANCE; end if;
				if c.state = ADVANCE and last = '1' then assert f.state = FETCH;   end if;
				if c.state = HALT then assert f.state = HALT; end if;
				if c.state = EXECUTE and last = '1' then
					assert f.state = ADVANCE or f.state = LOAD or f.state = STORE or f.state = FETCH;
				end if;
			end if;
			assert not (c.first xor f.dline(0) = '1') report "first/dline";
		end if;
	end process;

	process (i, c, cmd, ares, acout, last, last4) begin
		o       <= '0' after delay;
		a       <= '0' after delay;
		ie      <= '0' after delay;
		ae      <= '0' after delay;
		oe      <= '0' after delay;
		stop    <= '0' after delay;
		add1    <= '0' after delay;
		add2    <= '0' after delay;
		acin    <= '0' after delay;
		f       <= c after delay;
		f.dline <= c.dline(c.dline'high - 1 downto 0) & "0" after delay;

		-- Our delay line should only contain zero on one bit at a time
		if c.first then
			assert bit_count(c.dline) = 0 report "too many dline bits";
		else
			assert bit_count(c.dline) = 1 report "missing dline bit";
		end if;

		-- The processor works by using a delay line to sequence actions,
		-- the top four bits are used for the instruction (and if the highest
		-- bit is set indirection is _not_ allowed), with the lowest twelve
		-- bits as an operand to use as a literal value or an address.
		--
		-- As such, we will want to trigger actions when processing the first
		-- bit, the last four bits and the last bit.
		--
		if last = '1' then
			f.state <= c.choice after delay;
			f.first <= true     after delay;
			f.last4 <= false    after delay;
			-- This is a bit of a hack, in order to place it in its proper
			-- place within the 'FETCH' state we would need to move the
			-- 'indirection allowed on instruction' bit from the highest
			-- bit to a lower bit so we can perform the state decision before
			-- the bit is being processed.
			if c.flags(IND) = '1' and indirection then
				if i = '0' and c.state = FETCH then
					f.indir <= true;
					f.state <= INDIRECT; -- Override FETCH Choice!
				end if;
			end if;
		elsif last4 = '1' then
			f.last4 <= true after delay;
		end if;

		-- Each state lasts N (which defaults to 16) + 1 cycles.
		-- Of note: we could make the FETCH state last only 4 + 1 cycles
		-- and merge the operand fetching in FETCH (and OPERAND state) into
		-- the 'EXECUTE' state.
		--
		case c.state is
		when RESET   =>
			f.choice <= FETCH;
			if c.first then
				f.dline(0)  <= '1'   after delay;
				f.first     <= false after delay;
			else
				ae      <= '1' after delay;
				f.acc   <= "0" & c.acc(c.acc'high downto 1) after delay;
				f.pc    <= "0" & c.pc (c.pc'high  downto 1) after delay;
				f.op    <= "0" & c.op (c.op'high  downto 1) after delay;
				f.flags <= "0" & c.flags(c.flags'high downto 1) after delay;
			end if;
		-- When in the running state all state transitions pass through FETCH.
		-- FETCH does what you expect from it, it fetches the instruction. It also
		-- partially decodes it and sets flags that the accumulator depends on.
		-- 
		-- What is meant by partially decoding is this; it is determined if we
		-- should go to the INDIRECT state next or to the EXECUTE state, also
		-- it is determined whether an I/O operation should be performed for those
		-- instructions capable of doing I/O.
		when FETCH   =>
			if c.first then
				f.dline(0)   <= '1'    after delay;
				f.first      <= false  after delay;
				f.indir      <= false  after delay;
				f.flags(Z)   <= '1'    after delay;
				f.flags(PAR) <= parity after delay;
			else
				ie           <= '1' after delay;

				if c.acc(0) = '1' then -- determine flag status before EXECUTE
					f.flags(Z) <= '0' after delay;
				end if;
				f.flags(PAR) <= c.acc(0) xor c.flags(PAR) after delay;
				f.acc <= c.acc(0) & c.acc(c.acc'high downto 1) after delay;

				if not c.last4 then
					f.op    <= i & c.op(c.op'high downto 1) after delay;
				else
					f.cmd   <= i   & c.cmd(c.cmd'high downto 1) after delay;
					f.op    <= "0" & c.op (c.op'high  downto 1) after delay;
				end if;
			end if;

			-- We use the highest operand bit to determine whether an I/O operation
			-- is taking place with iGET and iSET.
			if c.op(c.op'high - 3) = '1' then
				f.is_io <= true after delay;
			else
				f.is_io <= false after delay;
			end if;

			f.flags(Ng)  <= c.acc(c.acc'high) after delay;

			-- NB. 'f.choice' may be overwritten for INDIRECT
			   if c.flags(HLT) = '1' then
				f.choice <= HALT after delay;
			elsif c.flags(R) = '1' then
				f.choice <= RESET after delay;
			else
				f.choice <= EXECUTE after delay;
			end if;
		-- INDIRECT is only used when we have c.flags(IND) set and the
		-- instruction allows for indirection (ie. All those instructions in which
		-- the top bit is not set). The indirection add 2*(N+1) cycles to
		-- the instruction so is quite expensive.
		when INDIRECT =>
			assert c.flags(IND) = '1' and c.cmd(c.cmd'high) = '0' severity error;
			f.choice <= EXECUTE after delay;
			if c.first then
				f.dline(0)  <= '1'   after delay;
				f.first     <= false after delay;
			else
				ae       <=     '1' after delay;
				a        <= c.op(0) after delay;
				f.op     <=     "0" & c.op(c.op'high downto 1) after delay;
				f.choice <= OPERAND after delay;
			end if;
		-- OPERAND fetches the operand *again*, this time using the operand
		-- acquired in EXECUTE, the address being set in the previous INDIRECT state.
		when OPERAND =>
			f.choice <= EXECUTE after delay;
			if c.first then
				f.dline(0) <= '1'   after delay;
				f.first    <= false after delay;
			else
				ie      <= '1' after delay;
				f.op    <= i & c.op(c.op'high downto 1) after delay;
			end if;
		-- The EXECUTE state implements the ALU. It is the most seemingly the
		-- most complex state, but it is not (FETCH is more difficult to
		-- understand).
		when EXECUTE =>
			assert not (c.flags(Z) = '1' and c.flags(Ng) = '1') report "zero and negative?";
			f.choice     <= ADVANCE after delay;
			if c.first then
				f.dline(0)  <= '1'   after delay;
				f.first     <= false after delay;
				f.tcarry    <= '1'   after delay;
			else
				case cmd is -- ALU
				when iOR =>
					f.op  <= "0" & c.op (c.op'high  downto 1) after delay;
					f.acc <= (c.op(0) or c.acc(0)) & c.acc(c.acc'high downto 1) after delay;
				when iAND =>
					f.acc <= c.acc(0) & c.acc(c.acc'high downto 1) after delay;
					if (not c.last4) or c.indir then
						f.op  <= "0" & c.op (c.op'high downto 1) after delay;
						f.acc <= (c.op(0) and c.acc(0)) & c.acc(c.acc'high downto 1) after delay;
					end if;
				when iXOR =>
					f.op  <= "0" & c.op (c.op'high downto 1) after delay;
					f.acc <= (c.op(0) xor c.acc(0)) & c.acc(c.acc'high downto 1) after delay;
				when iADD =>
					f.acc <= "0" & c.acc(c.acc'high downto 1) after delay;
					f.op  <= "0" & c.op(c.op'high downto 1)   after delay;
					add1  <=    c.acc(0) after delay;
					add2  <=     c.op(0) after delay;
					acin  <= c.flags(Cy) after delay;
					f.acc(f.acc'high) <= ares after delay;
					f.flags(Cy) <= acout after delay;
				-- A barrel shifter is usually quite an expensive piece of hardware,
				-- but it ends up being quite cheap for obvious reasons. If we really
				-- needed to we could dispense with the right shift, we could mask off
				-- low bits and rotate (either way) to emulate it.
				when iLSHIFT =>
					if c.op(0) = '1' then
						f.acc  <= c.acc(c.acc'high - 1 downto 0) & "0" after delay;
						if c.flags(ROT) = '1' then
							f.acc  <= c.acc(c.acc'high - 1 downto 0) & c.acc(0) after delay;
						end if;
					end if;
					f.op   <= "0" & c.op (c.op'high downto 1) after delay;
				when iRSHIFT =>
					if c.op(0) = '1' then
						f.acc  <= "0" & c.acc(c.acc'high downto 1) after delay;
						if c.flags(ROT) = '1' then
							f.acc  <= c.acc(0) & c.acc(c.acc'high downto 1) after delay;
						end if;
					end if;
					f.op   <= "0" & c.op (c.op'high downto 1) after delay;
				when iLOAD =>
					ae       <=     '1' after delay;
					a        <= c.op(0) after delay;
					f.op     <= c.op(0) & c.op(c.op'high downto 1) after delay;
					f.choice <= LOAD after delay;
				when iSTORE =>
					ae       <=     '1' after delay;
					a        <= c.op(0) after delay;
					f.op     <=     "0" & c.op(c.op'high downto 1) after delay;
					f.choice <= STORE after delay;
				when iLOADC =>
					ae       <=     '1' after delay;
					a        <= c.op(0) after delay;
					f.op     <= c.op(0) & c.op(c.op'high downto 1) after delay;
					f.choice <= LOAD after delay;
				when iSTOREC =>
					ae       <=     '1' after delay;
					a        <= c.op(0) after delay;
					f.op     <=     "0" & c.op(c.op'high downto 1) after delay;
					f.choice <= STORE after delay;
				when iLITERAL =>
					f.acc  <= c.op(0) & c.acc(c.acc'high downto 1) after delay;
					f.op   <=     "0" & c.op (c.op'high downto 1)  after delay;
				when iUNUSED =>
				-- We could use this if we need to extend the instruction set
				-- for any reason. I cannot think of a good one that justifies the
				-- cost of a new instruction. So this will remain blank for now.
				when iJUMP =>
					ae       <=     '1' after delay;
					a        <= c.op(0) after delay;
					f.op     <=     "0" & c.op(c.op'high downto 1) after delay;
					f.pc     <= c.op(0) & c.pc(c.pc'high downto 1) after delay;
					f.choice <= FETCH after delay;
				when iJUMPZ =>
					if c.flags(Z) = jumpz then
						ae     <=     '1' after delay;
						a      <= c.op(0) after delay;
						f.op   <=     "0" & c.op(c.op'high downto 1) after delay;
						f.pc   <= c.op(0) & c.pc(c.pc'high downto 1) after delay;
						f.choice <= FETCH after delay;
					end if;
				when iSET =>
					if c.is_io then
						ae     <=     '1' after delay;
						a      <= c.op(0) after delay;
						if last = '1' then
							a <= '1' after delay;
						end if;
						f.op     <=   "0" & c.op(c.op'high downto 1) after delay;
						f.choice <= STORE after delay;
					else
						if c.op(0) = '0' then
							-- NB. We could set the address directly here and
							-- go to FETCH but that costs us too much time and gates.
							f.pc     <= c.acc(0) & c.pc(c.pc'high downto 1) after delay;
							f.tcarry  <= '0' after delay;
						else
							f.flags  <= c.acc(0) & c.flags(c.flags'high downto 1) after delay;
						end if;
						f.acc    <= c.acc(0) & c.acc(c.acc'high downto 1) after delay;
					end if;
				when iGET =>
					if c.is_io then
						ae     <=     '1' after delay;
						a      <= c.op(0) after delay;
						if last = '1' then
							a <= '1' after delay;
						end if;
						f.op     <= "0" & c.op(c.op'high downto 1) after delay;
						f.choice <= LOAD after delay;
					else
						if c.op(0) = '0' then
							f.acc    <= c.pc(0) & c.acc(c.acc'high downto 1) after delay;
							f.pc     <= c.pc(0) & c.pc(c.pc'high downto 1) after delay;
						else
							f.acc    <= c.flags(0) & c.acc(c.acc'high downto 1) after delay;
							f.flags  <= c.flags(0) & c.flags(c.flags'high downto 1) after delay;
						end if;
					end if;
				end case;
			end if;
		-- Unfortunately we cannot perform a load or a store whilst we are
		-- performing an EXECUTE, so we require STORE and LOAD states to do
		-- more work after a LOAD or STORE instruction.
		when STORE   =>
			f.choice <= ADVANCE after delay;
			if c.first then
				f.dline(0) <= '1'   after delay;
				f.first    <= false after delay;
			else
				o      <= c.acc(0) after delay;
				oe     <= '1'      after delay;
				f.acc  <= c.acc(0) & c.acc(c.acc'high downto 1) after delay;
			end if;
		when LOAD    =>
			f.choice <= ADVANCE after delay;
			if c.first then
				f.dline(0) <= '1'   after delay;
				f.first    <= false after delay;
			else
				ie    <= '1' after delay;
				f.acc <= i & c.acc(c.acc'high downto 1) after delay;
			end if;
		-- ADVANCE reuses our adder in iADD to add one to the program counter
		-- this state should not be reached from iJUMPZ or iJUMP, or when
		-- performing an iSET on the program counter.
		when ADVANCE =>
			f.choice <= FETCH after delay;
			if c.first then
				f.dline(0) <= '1'   after delay;
				f.first    <= false after delay;
			else
				f.pc <= "0" & c.pc(c.pc'high downto 1) after delay;
				add1 <= c.pc(0)  after delay;
				add2 <= '0'      after delay;
				acin <= c.tcarry after delay;
				f.pc(f.pc'high) <= ares  after delay;
				a               <= ares  after delay;
				f.tcarry        <= acout after delay;
				ae   <= '1' after delay;
			end if;
		when HALT => stop <= '1' after delay;
		end case;
	end process;
end architecture;

