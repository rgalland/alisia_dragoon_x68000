CC=/home/regis/My_Games/MD/vasm/vasmm68k_mot
LK=/home/regis/My_Games/MD/vlink/vlink

all: sega_logo_x68k.s
	echo "Compiling X68000 MD Logo test"
	$(CC) sega_logo_x68k.s -Felf -o segalogo.o -L segalogo.lst -m68000 -DBuildX68=1
	$(LK) segalogo.o -bxfile -o "bldX68k/segalogo.x"
