CC=gcc
CFLAGS=-Wall -Wextra -std=c99 -O2
.PHONY: all run simulate viewer clean

all: bit simulate

run: bit bit.hex
	./bit -r bit.hex

simulate: tb.ghw

viewer: tb.ghw
	gtkwave -f $< &> /dev/null&

%.hex: %.asm bit
	./bit -a $< $@

bit: bit.c
	${CC} ${CFLAGS} $< -o $@

%.o: %.vhd
	ghdl -a -g $<

top.o: mem.o bit.o

tb.o: tb.vhd bit.o mem.o top.o

tb: tb.o bit.o mem.o top.o
	ghdl -e tb

tb.ghw: tb bit.hex
	ghdl -r $< --wave=$<.ghw --max-stack-alloc=16384 --ieee-asserts=disable

SOURCES = \
	top.vhd \
	bit.vhd \
	mem.vhd

OBJECTS = ${SOURCES:.vhd=.o}

bitfile: design.bit

reports:
	@[ -d reports    ]    || mkdir reports
tmp:
	@[ -d tmp        ]    || mkdir tmp
tmp/_xmsgs:
	@[ -d tmp/_xmsgs ]    || mkdir tmp/_xmsgs

tmp/top.prj: tmp
	@rm -f tmp/top.prj
	@( \
	    for f in $(SOURCES); do \
	        echo "vhdl work \"$$f\""; \
	    done; \
	    echo "vhdl work \"top.vhd\"" \
	) > tmp/top.prj

tmp/top.lso: tmp
	@echo "work" > tmp/top.lso

tmp/top.xst: tmp tmp/_xmsgs tmp/top.lso tmp/top.lso
	@( \
	    echo "set -tmpdir \"tmp\""; \
	    echo "set -xsthdpdir \"tmp\""; \
	    echo "run"; \
	    echo "-lso tmp/top.lso"; \
	    echo "-ifn tmp/top.prj"; \
	    echo "-ofn top"; \
	    echo "-p xc6slx16-csg324-3"; \
	    echo "-top top"; \
	    echo "-opt_mode speed"; \
	    echo "-opt_level 2" \
	) > tmp/top.xst

synthesis: reports tmp tmp/_xmsgs tmp/top.prj tmp/top.xst
	@echo "Synthesis running..."
	@${TIME} xst -intstyle silent -ifn tmp/top.xst -ofn reports/xst.log
	@mv _xmsgs/* tmp/_xmsgs
	@rmdir _xmsgs
	@mv top_xst.xrpt tmp
	@grep "ERROR\|WARNING" reports/xst.log | \
	 grep -v "WARNING.*has a constant value.*This FF/Latch will be trimmed during the optimization process." | \
	 cat
	@grep ns reports/xst.log | grep 'Clock period'

implementation: reports tmp
	@echo "Implementation running..."
	
	@[ -d tmp/xlnx_auto_0_xdb ] || mkdir tmp/xlnx_auto_0_xdb

	@${TIME} ngdbuild -intstyle silent -quiet -dd tmp -uc top.ucf -p xc6slx16-csg324-3 top.ngc top.ngd
	@mv top.bld reports/ngdbuild.log
	@mv _xmsgs/* tmp/_xmsgs
	@rmdir _xmsgs
	@mv xlnx_auto_0_xdb/* tmp
	@rmdir xlnx_auto_0_xdb
	@mv top_ngdbuild.xrpt tmp

	@${TIME} map -intstyle silent -detail -p xc6slx16-csg324-3 -pr b -c 100 -w -o top_map.ncd top.ngd top.pcf
	@mv top_map.mrp reports/map.log
	@mv _xmsgs/* tmp/_xmsgs
	@rmdir _xmsgs
	@mv top_usage.xml top_summary.xml top_map.map top_map.xrpt tmp

	@${TIME} par -intstyle silent -w -ol std top_map.ncd top.ncd top.pcf
	@mv top.par reports/par.log
	@mv top_pad.txt reports/par_pad.txt
	@mv _xmsgs/* tmp/_xmsgs
	@rmdir _xmsgs
	@mv par_usage_statistics.html top.ptwx top.pad top_pad.csv top.unroutes top.xpi top_par.xrpt tmp
	
	@#trce -intstyle silent -v 3 -s 3 -n 3 -fastpaths -xml top.twx top.ncd -o top.twr top.pcf -ucf top.ucf
	@#mv top.twr reports/trce.log
	@#mv _xmsgs/* tmp/_xmsgs
	@#rmdir _xmsgs
	@#mv top.twx tmp

	@#netgen -intstyle silent -ofmt vhdl -sim -w top.ngc top_xsim.vhd
	@#netgen -intstyle silent -ofmt vhdl -sim -w -pcf top.pcf top.ncd top_tsim.vhd
	@#mv _xmsgs/* tmp/_xmsgs
	@#rmdir _xmsgs
	@#mv top_xsim.nlf top_tsim.nlf tmp


design.bit: reports tmp/_xmsgs
	@echo "Generate bitfile running..."
	@touch webtalk.log
	@${TIME} bitgen -intstyle silent -w top.ncd
	@mv top.bit design.bit
	@mv top.bgn reports/bitgen.log
	@mv _xmsgs/* tmp/_xmsgs
	@rmdir _xmsgs
	@sleep 5
	@mv top.drc top_bitgen.xwbt top_usage.xml top_summary.xml webtalk.log tmp
	@grep -i '\(warning\|clock period\)' reports/xst.log

upload: 
	djtgcfg prog -d Nexys3 -i 0 -f design.bit

design: clean simulation synthesis implementation bitfile

postsyn:
	@netgen -w -ofmt vhdl -sim ${NETLIST}.ngc post_synthesis.vhd
	@netgen -w -ofmt vhdl -sim ${NETLIST}.ngd post_translate.vhd
	@netgen  -pcf ${NETLIST}.pcf -w -ofmt vhdl -sim ${NETLIST}.ncd post_map.vhd

clean:
	@echo "Deleting temporary files and cleaning up directory..."
	@rm -fv *.cf *.o *.ghw *.hex tb bit
	@rm -vf *~ *.o trace.dat tb tb.ghw work-obj93.cf top.ngc top.ngd top_map.ngm \
	      top.pcf top_map.ncd top.ncd top_xsim.vhd top_tsim.vhd top_tsim.sdf \
	      top_tsim.nlf top_xst.xrpt top_ngdbuild.xrpt top_usage.xml top_summary.xml \
	      top_map.map top_map.xrpt par_usage_statistics.html top.ptwx top.pad top_pad.csv \
	      top.unroutes top.xpi top_par.xrpt top.twx top.nlf design.bit top_map.mrp 
	@rm -vrf _xmsgs reports tmp xlnx_auto_0_xdb
	@rm -vrf _xmsgs reports tmp xlnx_auto_0_xdb
	@rm -vrf *.pdf *.htm
	@rm -vrf *.sym
	@rm -vrf xst/
	@rm -vf usage_statistics_webtalk.html

