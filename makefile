CC=/home/regis/My_Games/MD/vasm/vasmm68k_mot
LK=/home/regis/My_Games/MD/vlink/vlink

st: soundtest.s
	echo "Compiling X68000 Sound test"
#	$(CC) soundtest.s -m68000 -L soundtest.lst -DBuildX68=1 -Fxfile -o soundtest.x
	$(CC) soundtest.s -Felf -o soundtest.o -L "bldX68k/soundtest.lst" -m68000 -DBuildX68=1
	$(LK) soundtest.o -bxfile -o "bldX68k/soundtest.x"

sd: sound_driver.s
	echo "Compiling X68000 Sound driver"
	$(CC) sound_driver.s -m68000 -L sound_driver.lst -DBuildX68=1 -Fxfile -o sound_driver.x
	cp sound_driver.x disk/
	
