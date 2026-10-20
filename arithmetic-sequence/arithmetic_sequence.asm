	global arithmetic_sequence

	section .text

arithmetic_sequence:
	; Argumenty:
	; RDI - A0
	; RSI - A1
	; RDX - Ak
	; RCX - n
	; R8 - k

	; Zapisujemy stan calle-saved rejestrów, z których będziemy korzystać.
	push rbx

	mov rbx, rdx ; Zapisujemy Ak w RBX.
	
	; Będziemy używali R11 jako offsetu by iterować po A0 i A1. Dlatego
	; musimy go najpierw wyzerować.
	xor r11d, r11d

	; Ustawiamy R9 na same jedynki gdy A1 < 0 i na 0 gdy A1 >= 0.
	; Analogicznie robimy z R10, tylko że R10 będzie maską znaku A1.
	mov r9, [rsi + rcx * 8 - 8]
	sar r9, 63 ; R9 jest teraz maską znaku A1.

	mov r10, [rdi + rcx * 8 - 8]
	sar r10, 63 ; R10 jest teraz maską znaku A0.

	clc ; Czyścimy carry, potencjalnie ustawione przez przesunięcie SAR.

.sub_A0_from_A1_loop:
	; Ustawiamy RAX = A1[i]
	mov rax, [rsi + r11]

	; RAX -= A0[i]
	sbb rax, [rdi + r11]
	
	; Ak[i] = RAX
	mov [rbx + r11], rax
	
	; Logika pętli
	lea r11, [r11 + 8]
	loop .sub_A0_from_A1_loop
	
	; Musimy teraz "przedłużyć" naszą różnicę o 64 bity.
	; W tym celu ustawiamy R9 na same jedynki gdy A1 - A0 < 0 i
	; same zera gdy A1 - A0 >= 0.
	sbb r9, r10 ; R9 jest teraz maską znaku A1 - A0 (bo R9 przed tą 
		    ; instrukcją było maską znaku A1, a R10 - maską znaku A0).

	; Zapisujemy kopię k w RSI
	mov rsi, r8

	; Przed mnożeniem razy k, ustawiamy k = |k|. Oryginalna wartość k jest
	; w RSI, więc jej nie stracimy.
	test r8, r8
	jge .k_multiplication

	neg r8
	
.k_multiplication:
	; RCX = R11 / 8 = n (bo po pętli R11 = 8 * n)
	mov rcx, r11
	shr rcx, 3

	; Będziemy używali R11 jako offsetu by iterować po Ak oraz R10 by
	; zapisywać resztę z mnożenia.
	xor r11d, r11d
	xor r10d, r10d

.multiply_by_k_loop:
	; RAX = Ak[i]
	mov rax, [rbx + r11]

	; RAX *= k
	mul r8
	
	; Dodajemy resztę z poprzedniego mnożenia
	add rax, r10

	; Ustawiamy Ak[i] na mniejsze 64 bity wyniku
	mov [rbx + r11], rax
	
	; Jeżeli dodawanie wygenerowało carry, chcemy je dodać do
	; naszej reszty
	adc rdx, 0

	; Zapisujemy resztę w R10
	mov r10, rdx

	; Logika pętli
	lea r11, [r11 + 8]
	loop .multiply_by_k_loop

	and r9, r8 ; Jeżeli A1 - A0 < 0, to chcemy R9 = k, wpp. R9 = 0.
		   ; Skoro R9 to same jedynki wtw. A1 - A0 < 0 i R9 = 0 wpp.
		   ; to używamy operatora logicznego AND.

	; Ustawiamy najstarsze 128 bitów po mnożeniu.

	; R10 będzie przechowywać młodsze 64 bity nadwyżki. Skoro już znajduje
	; się w nim reszta po mnożeniu, nie musimy zmieniać teraz jego wartości;

	xor r8d, r8d ; R8 będzie przechowywać starsze 64 bity nadwyżki (po tym
		   ; jak ustawiliśmy R9, wartość k przechowywana dotychczas w
		   ; R8 nie jest nam już potrzebna)


	; Zauważmy, że jeżeli A1 - A0 było ujemne, to w wyniku naszego mnożenia
	; otrzymamy (2^64)*k + (A1 - A0) * k. Zatem, żeby uzyskać prawidłowy wynik,
	; dla A1 - A0 < 0 należy odjąć k od niższych 64 bitów nadwyżki, a dla 
	; A1 - A0 >= 0, nie należy nic robić. Skoro R9 = k gdy A1 - A0 < 0 i
	; R9 = 0 gdy A1 - A0 >= 0, wystarczy odjąć R9.
	sub r10, r9
	sbb r8, 0

	; Teraz pozostało nam uwzględnić wyraz początkowy naszego ciągu.
	; Jeżeli k < 0, chcemy ustawić Ak = A0 - k * (A1 - A0), czyli
	; Ak = A0 - Ak. W przeciwnym przypadku, chcemy ustawić Ak = A0 + Ak.
	; W tym celu, jeżeli k < 0, negujemy Ak. Potem dodajemy A0 do naszego
	; (potencjalnie zanegowanego) Ak.
	test rsi, rsi ; Sprawdzamy czy k >= 0.
	jns .add_A0 ; Jeżeli k >= 0, pomijamy kod negujący Ak.

	; Jeżeli k < 0, chcemy ustawić Ak = - Ak
	; Przygotowanie do pętli
	; RCX = R11 / 8 = n (zawsze po końcu pętli R11 = 8*n)
	mov rcx, r11
	shr RCX, 3

	mov r11, 8

	; Negujemy bity najniższego słowa i dodajemy do niego 1
	; (w U2 mamy -Ak = NOT(Ak) + 1).
	not qword [rbx]
	add qword [rbx], 1

	dec rcx ; RCX = n - 1
	jz .negate_higher_Ak_bits ; Jeżeli n = 1, nie chemy wejść do pętli, bo
				  ; do zanegowania zostało nam tylko nawyższe
				  ; 128 bitów.

.negate_Ak_loop:
	not qword [rbx + r11] ; Negujemy bity RCX-tego słowa
	adc qword [rbx + r11], 0 ; Dodajemy nadwyżkę, która nam potencjalnie
			   	 ; powstała Po tym jak dodawaliśmy 1 do 
			   	 ; najniższego słowa.

	; Logika pętli
	lea r11, [r11 + 8]
	loop .negate_Ak_loop
	
.negate_higher_Ak_bits:
	; Robimy to samo (negujemy bity i dodajemy nadwyżkę) dla najwyższych
	; 128 bitów Ak.
	not r10
	not r8
	adc r10, 0
	adc r8, 0
	
.add_A0:
	; RCX = R11 / 8 = n
	mov rcx, r11
	shr rcx, 3

	; Będziemy używali R11 jako offsetu by iterować po Ak oraz A0.
	xor r11d, r11d

.add_A0_loop:
	; Ustawiamy Ak[i] += A0[i]
	mov rax, [rbx + r11]
	adc rax, [rdi + r11]
	mov [rbx + r11], rax

	; Logika pętli
	lea r11, [r11 + 8]
	loop .add_A0_loop
	
	; Dodajemy nadwyżkę do naszych najwyższych 128 bitów.
	adc r10, 0
	adc r8, 0

	; RCX = R11 / 8 = n
	mov rcx, r11
	shr rcx, 3

	; Jeżeli A0 < 0, to po rozszerzeniu A0 do zapisu zawierającego n + 2 
	; słów (64-bitowych fragmentów), najwyższe 128 bitów zapisu A0 to 
	; byłyby same jedynki. Dlatego jeżeli A0 < 0, to do najwyższych 128 
	; bitów naszego wyniku musimy dodać liczbę składająca się z 
	; samych jedynek.
	mov rax, [rdi + rcx * 8 - 8] ; Ustawiamy RAX na najwyższe 64 bity A0.
	sar rax, 63 ; Po tym przesunięciu RAX = 0 gdy A0 >= 0 i RAX = -1 gdy
		    ; A0 < 0. W U2 zapis -1 to same jedynki.

	add r10, rax
	adc r8, rax

	; Najwyższe 128 bitów znajduje się w r10 i r8. Chcemy je zwrócić.
	mov rax, r10
	mov rdx, r8

	; Przywracamy stan calle-saved rejestrów.
	pop rbx

	ret
