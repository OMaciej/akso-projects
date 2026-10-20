CFLAGS = -Wall -Wextra -std=c23 -O2

.PHONY: all clean

all: arithmetic_sequence.o example

arithmetic_sequence.o: arithmetic_sequence.asm
	nasm -f elf64 -w+all -w+error -o arithmetic_sequence.o arithmetic_sequence.asm

example: arithmetic_sequence.o arithmetic_sequence_example.c
	gcc -c $(CFLAGS) -o arithmetic_sequence_example_c.o arithmetic_sequence_example.c
	gcc -z noexecstack -o $@ arithmetic_sequence_example_c.o arithmetic_sequence.o

gemtest: gem_test.c
	gcc -c $(CFLAGS) -o gemtest.o gem_test.c
	gcc gemtest.o arithmetic_sequence.o -o $@

clean:
	rm *.o example gemtest
