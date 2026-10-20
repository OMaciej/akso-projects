global _start
default rel ; Mówimy NASMowi, żeby używał adresowania względem RIP.

; Stałe
ASCII_0 equ 48 ; Kod ASCII odpowiadający znakowi '0'.
ASCII_9 equ 57 ; Kod ASCII odpowiadający znakowi '9'.
ASCII_NEWLINE equ 10 ; Kod ASCII odpowiadający znakowi nowej linii.
FIRST_VISIBLE_ASCII_CHAR equ 33 ; Kod ASCII odpowiadający znakowi '!'. Jest to
				; najmniejszy kod ASCII odpowiadający
				; "normalnemu" (takiemu, który jesteśmy w 
				; stanie wyświetlić) znakowi.
LAST_VISIBLE_ASCII_CHAR equ 126 ; Kod ASCII odpowiadający znakowi '~'. Jest to
				; największy kod ASCII odpowiadający
				; "normalnemu" znakowi.

MAX_N equ 0xffffffff ; Maksymalna wartość n (2^32 - 1).
INITIAL_INPUT_BUFFER_SIZE equ 65536 ; Początkowy rozmiar bufora wejścia (64kb).
OUTPUT_BUFFER_SIZE equ 65536 ; Początkowy rozmiar bufora wyjścia (64kb).
INITIAL_STACK_SIZE equ 65536 ; Początkowy rozmiar alokowanego przez nas stosu,
			     ; używanego do implementacji DFSa bez użycia stosu
			     ; systemowego (64kb).

; Funkcje systemowe
SYS_EXIT equ 60
SYS_MMAP equ 9
SYS_MREMAP equ 25
SYS_MUNMAP equ 11
SYS_READ equ 0
SYS_WRITE equ 1

STDIN equ 0
STDOUT equ 1

; Flagi dla sys_mmap() i sys_mremap().
PROT_READ equ 1 ; Flaga odpowiadająca za to, by można było odczytywać 
		; alokowaną przez nas pamięć.
PROT_WRITE equ 2 ; Flaga odpowiadająca za to, by można było zapisywać do
		 ; alokowanej przez nas pamięci.
MAP_PRIVATE equ 2 ; Flaga mowiąca, że zaalokowana przez nas pamięć nie może być
		  ; wspóldzielona z innymi procesami.
MAP_ANON equ 32 ; Flaga mówiąca, że chcemy po prostu dostać fragment pamięci,
		; a nie załadować jakiś plik do pamięci.
MREMAP_MAYMOVE equ 1 ; Flaga  na przeniesienie naszego bufora do innego
		     ; miejsca w pamięci, jeżeli w obecnym miejscu nie ma
		     ; miejsca, by go zwiększyć.

section .bss
starting_symbol_ptr resq 1 ; Przechowuje wskaźnik do symbolu początkowego.

; Tablica przechowująca nasze reguły zamiany. Każda reguła odpowiada jakiemuś
; znakowi, stąd jej rozmiar.
rules resq 128

; Stos, którego będziemy używać. Ze względu na potencjalnie duży rozmiar danych
; wejściowych oraz względnie niewielki rozmiar stosu systemowego, będziemy
; korzystać z własnego stosu.
stack_base resq 1 ; Baza naszego stosu.
stack_size resq 1 ; Rozmiar naszego stosu.

; Bufor wyjściowy. Wywoływanie sys_write jest potencjalnie kosztowne. Dlatego
; tworzymy duży bufor wyjściowy i wypisujemy za pomocą sys_write dopiero gdy 
; się zapełni.
input_buffer resq 1 ; Wskaźnik na bufor wejściowy.
input_buffer_size resq 1 ; Rozmiar bufora wejściowego.

exit_code resd 1 ; Kod wyjścia naszego programu. Domyślnie, jak wszystkie
		 ; zmienne z .bss, jest równy 0.

section .text

_start:
	xor r14d, r14d ; W R14 będziemy przechowywać wskaźnik na bufor
		       ; wyjściowy. Zerujemy R14, żeby nasz kod,
		       ; który zwalnia pamięć i kończy program, mógł poprawnie
		       ; sprawdzić, czy alokowaliśmy bufor wyjściowy, 
		       ; porównując R14 z zerem.

	; Wczytujemy argument podany do programu przez użytkownika i sprawdzamy
	; jego poprawność.

	; Jeżeli użytkownik podał poprawną liczbę argumentów, to argc = 2.
	; Zatem jeżeli argc != 2, użytkownik podał za mało lub za dużo
	; argumentów.
	mov rax, [rsp] ; RAX = argc
	cmp rax, 2 ; Porównujemy argc z 2.
	jne .exit_fail ; Jeżeli argc != 2, dane podane przez użytkownika są
		      ; nieprawidłowe. Kończymy więc program.

	; Ustawiamy RCX na wskaźnik do początku napisu reprezentującego n,
	; tzn. na argv[1].
	mov rcx, [rsp + 16]

	; Wewnątrz pętli wczytującej argument do programu (n):
	; RBX - wczytana wartość n
	; RDX - znak reprezentujący kolejną cyfrę n.
	; RCX - iterator po zapisie dziesiętnym n (wskaźnik na znak).

	; W RBX będziemy zapisywać n.
	xor ebx, ebx
	
	; RDX ustawiamy na pierwszy znak zapisu dziesiętnego n.
	movzx rdx, byte [rcx]

.convert_n_to_number_loop:
	; Będziemy wczytywać zapis dziesiętny n i konwertować go na liczbę.

	; Sprawdzamy poprawność danych (sprawdzamy czy nasz znak jest cyfrą).
	; W tym celu sprawdzamy czy kod naszego znaku mieści się między kodem
	; reprezentującym '0', a kodem reprezentującym '9'.
	cmp rdx, ASCII_0
	jb .exit_fail

	cmp rdx, ASCII_9
	ja .exit_fail

	sub rdx, ASCII_0 ; Ustawiamy RDX na obecnie dopisywaną cyfrę (na jej
			 ; reprezentację liczbową, a nie napisową).

	; Dodajemy kolejną cyfrę na koniec n. W tym celu przesuwamy całą
	; liczbę w lewo i dodajemy naszą cyfrę (RDX) na koniec.
	; Stąd RBX = RBX * 10 + RDX.
	imul rbx, 10 ; RBX *= 10
	add rbx, rdx ; RBX += (kolejna cyfra)
	
	; Sprawdzamy czy do tej pory wczytana wartość liczby n nie 
	; wykracza poza zakres.
	mov rax, MAX_N
	cmp rbx, rax ; Porównujemy nasz do tej pory wczytany fragment n z
		     ; maksymalną wartością n.
	ja .exit_fail ; Jeżeli jest większy niż maksymalna możliwa wartość n,
		      ; argument podany przez użytkownika jest nieprawidłowy.

	; Ustawiamy RCX na wskaźnik na kolejny znak zapisu dziesiętnego n.
	inc rcx

	; Ustawiamy RDX na kolejny znak zapisu dziesiętnego n.
	movzx rdx, byte [rcx]

	; Jeżeli kolejny znak to NULL, to wczytaliśmy już cały napis.
	; Chcemy więc wtedy wyjść z pętli.
	test rdx, rdx
	jnz .convert_n_to_number_loop


	; Wczytujemy reguły.
	; Alokujemy bufor, w którym zapiszemy wejście. Korzystamy do tego z
	; sys_mmap().
	mov eax, SYS_MMAP
	xor edi, edi ; Chcemy, żeby system operacyjny sam wybrał adres naszego
		     ; bufora.
	mov rsi, INITIAL_INPUT_BUFFER_SIZE ; Chcemy zaalokować 
					   ; INITIAL_INPUT_BUFFER_SIZE bajtów.
	mov edx, PROT_READ | PROT_WRITE ; Flagi dotyczące ochrony obszaru 
					; pamięci, który zaalokujemy.
	mov r10d, MAP_PRIVATE | MAP_ANON ; Chcemy, żeby nasz zaalokowany obszar
					 ; nie mógł zostać użyty przez inne
					 ; procesy.
	mov r8, -1 ; fd = -1
	xor r9, r9 ; offset = 0
	syscall

	; Sprawdzamy, czy nasza alokacja zakończyła się sukcesem.
	test rax, rax
	js .exit_fail ; Jeśli sys_mmap() zwrócił wartość mniejszą od 0, wystąpił
		     ; błąd alokacji.
	
	; W kodzie wczytującym dane wejściowe:
	; R12 - wskaźnik na początek bufora wejściowego.
	; R13 - rozmiar bufora wejściowego.
	; R15 - ilość wczytanych bajtów.
	; RDX - ilość wolnego miejsca w buforze (w bajtach).
	
	mov r12, rax ; Zapisujemy adres zaalokowanego na bufor obszaru pamięci
		     ; w RAX.
	mov r13d, INITIAL_INPUT_BUFFER_SIZE ; W R13 będziemy trzymać obecny 
					    ; rozmiar bufora.
	mov r15d, 0 ; W R15 będziemy przechowywać ilość już 
		    ; wczytanych bajtów.

.read_from_stdin_loop:
	; Sprawdzamy czy jeszcze jest miejsce w naszym buforze
	mov rdx, r13 ; RDX = rozmiar bufora
	sub rdx, r15 ; RDX = rozmiar bufora - ilość bajtów już zapisanych
	jnz .read_to_buffer ; Jeżeli RDX != 0, to mamy jeszcze miejsce w naszym
			   ; buforze. Zatem wczytujemy dane do naszego bufora.
	
	; Jeżeli zabrakło miejsca w buforze, musimy zwiększyć jego rozmiar za
	; pomocą sys_mremap().
	mov eax, SYS_MREMAP
	mov rdi, r12 ; addr = obecny adres naszego bufora.
	mov rsi, r13 ; old_len = obecny rozmiar naszego bufora.
	; RDX opdowiada za argument new_len. Chcemy przekazać 
	; new_len = 2*old_len. 
	mov rdx, r13 ; RDX = old_len
	shl rdx, 1 ; RDX *= 2
	mov r10, MREMAP_MAYMOVE ; Mówimy funkcji sys_mremap, że, jeżeli to
				; konieczne, może przenieść nasz bufor do
				; innego miejsca w pamięci.
	syscall
	
	; Sprawdzamy czy wywołanie sys_mremap() zakońcyzło się sukcesem.
	test rax, rax
	js .exit_fail ; Jeżeli sys_mremap() zwrócił wartość ujemną, wystąpił
		      ; błąd.

	mov r12, rax ; Aktualizujemy adres bufora na ten zwrócony
		     ; przez sys_mremap().
	shl r13, 1 ; Rozmiar naszego bufora się podwoił.

	jmp .read_from_stdin_loop ; Wracamy na początek pętli. Robimy to tylko
				  ; po to by ustawić RDX = ilość wolnego miejsca
				  ; w buforze.

.read_to_buffer:
	; Czytamy do bufora za pomocą sys_read().
	mov eax, SYS_READ
	mov edi, STDIN ; fd = STDIN (czytamy ze standardowego wejścia).

	; buf = początek bufora + ilość wczytanych bajtów
	mov rsi, r12 ; RSI = początek bufora
	add rsi, r15 ; RSI += ilość wczytanych bajtów
	; count (argument przekazywany przez RDX) został już obliczony i jest
	; równy ilości wolnego miejsca w naszym buforze.
	syscall


	; Sprawdzamy czy sys_read() zakończył się sukcesem oraz czy doszlśmy do
	; końca pliku.
	test rax, rax
	js .exit_fail ; Jeżeli sys_read() zwrócił wartość
					    ; ujemną, wystąpił błąd.
	jz .end_read  ; Jeżeli sys_read() wczytał 0 bajtów, jesteśmy na końcu
	              ; pliku.
	
	add r15, rax ; Zwiększamy ilość wczytanych bajtów o to, ile bajtów
		     ; wczytał sys_read().

	jmp .read_from_stdin_loop ; Wracamy na początek pętli.

.end_read:
	; W kodzie parsującym wejście:
	; RSI - iterator po wejściu (buforze wejściowym).
	; R15 - wskaźnik na koniec wejścia.
	; RDX - znak, na który obecnie wskazuje iterator.
	; RDI - wskaźnik na początek tablicy rules (tablicy reguł).

	; Teraz będziemy parsować wejście.
	; W RSI będzie znajdować się nasz iterator po wejściu.
	mov rsi, r12

	; R15 będzie wskaźnikiem na koniec wejścia.
	; W tym celu ustawiamy R15 = wskaźnik na początek bufora + 
	; + ilość wczytanych bajtów. Skoro w R15 już przechowujemy liczbę
	; wczytanych bajtów, to wystarczy R15 += R12.
	add r15, r12
	
	; Na początku naszego bufora znajduje się symbol początkowy. Zapisujemy
	; go (a w zasadzie wskaźnik do niego) w starting_symbol_ptr.
	mov [starting_symbol_ptr], r12

	lea rdi, [rules] ; Zapisujemy w RDI wskaźnik na tablicę, w której
			 ; będziemy zapisywać reguły.

	; Będziemy sprawdzać, czy pierwsza linijka wejścia, zawierająca symbol
	; startowy, jest prawidłowa. To znaczy, sprawdzimy czy nasz symbol
	; startowy nie zawiera nieprawidłowych znaków oraz czy linia wejścia
	; kończy się znakiem nowej linii.

.validate_starting_symbol_loop:
	; Sprawdzamy, czy doszliśmy do końca wejścia zanim pojawił się znak
	; nowej linii. W tym celu porównujemy wskaźnik na miejsce w buforze,
	; w którym kończy się wejścia (R15) z naszym iteratorem (RSI).
	; Jeżeli tak się stało, to wejście jest nieprawidłowe, bo każda
	; linia wejścia powinna się kończyć znakiem nowej linii. Zgłaszamy więc
	; błąd.
	cmp rsi, r15
	je .exit_fail

	; Pobieramy znak, na który wskazuje nasz iterator.
	movzx rdx, byte [rsi]

	; Sprawdzamy, czy doszliśmy już do końca pierwszej linii.
	cmp rdx, ASCII_NEWLINE ; Sprawdzamy, czy trafiliśmy już na znak
			       ; nowej linii.
	; Jeżeli trafiliśmy na znak nowej linii, to znaczy, że przeszliśmy
	; już przez całą pierwszą linię wejścia. Chcemy więc wyjść z pętli oraz
	; zacząć wczytywać reguły. W przeciwnym przypadku kontynuujemy pętlę.
	je .parse_new_rule

	; Sprawdzamy czy znak, na który wskazuje nasz iterator jest prawidłowy.
	cmp rdx, FIRST_VISIBLE_ASCII_CHAR
	jb .exit_fail
	cmp rdx, LAST_VISIBLE_ASCII_CHAR
	ja .exit_fail

	; Logika pętli.
	inc rsi ; Zwiększamy iterator.
	jmp .validate_starting_symbol_loop ; Wracamy na początek pętli.

.parse_new_rule:
	; W tym momencie wiemy, że rsi wskazuje na znak nowej linii. Jesteśmy
	; więc na początku nowej reguły.
	mov byte [rsi], 0 ; Zastępujemy znak nowej lini NULLem, żeby mieć
			  ; null-terminated string.

	inc rsi ; Zwiększamy rsi, by wskazywał na znak zastępowany w naszej
		; regule.
	
	; Sprawdzamy, czy przypadkiem nie doszliśmy właśnie na koniec wejścia.
	cmp rsi, r15 ; Porównujemy iterator ze wskaźnikiem na koniec wejścia.
	je .parse_rules_done ; Jeżeli iterator = koniec wejścia, to
			    ; sparsowaliśmy już całe wejście. Wychodzimy z
			    ; pętli.
	
	movzx rdx, byte [rsi] ; Pobieramy pierwszy znak reguły.

	; Sprawdzamy prawidłowość pierwszego znaku reguły.
	cmp rdx, FIRST_VISIBLE_ASCII_CHAR
	jb .exit_fail
	cmp rdx, LAST_VISIBLE_ASCII_CHAR
	ja .exit_fail

	; Sprawdzamy czy dla danego znaku nie jest już określona jakaś reguła.
	; Dla każdego znaku może być określona maksymalnie jedna reguła, więc
	; jeżeli jakaś już jest zapisana, zgłaszamy błąd.
	mov rax, qword [rdi + rdx * 8] ; Wczytujemy w RAX regułę zapisaną dla 
				       ; naszego znaku.
	
	; Jeżeli reguły nie ma, to nasza tablica w tym miejscu powinna być
	; równa zero. Sprawdzamy to.
	test rax, rax
	jnz .exit_fail ; Była już zapisana jakaś reguła. Wejście
		       ; jest nieprawidłowe. Zgłaszamy błąd.
	
	; Zwiększamy iterator.
	inc rsi

	; Zapisujemy wskaźnik do naszej nowej reguły.
	mov [rdi + rdx * 8], rsi ; Zapisujemy nową regułę do tablicy.

.validate_rule_characters_loop:
	; Dopóki nie natrafimy na koniec reguły (znak nowej linii), sprawdzamy
	; poprawność znaków naszej obecnej reguły.

	; Jeżeli trafiliśmy na koniec wejścia, to ostatnia linia nie była
	; zakończona znakiem nowej linii. Wejście jest wtedy nieprawidłowe,
	; więc w takim przypadku zgładzamy błąd.
	cmp rsi, r15 ; Porównujemy iterator ze wskaźnikiem na koniec wejścia.
	je .exit_fail ; Jeśli doszliśmy na koniec wejścia,
		      ; zgłaszamy błąd (brak znaku nowej linii).
	
	; Wczytujemy znak, na który wskazuje nasz iterator.
	movzx rdx, byte [rsi]

	; Jeżeli trafiliśmy na znak nowej linii, rozpoczynamy wczytywanie nowej
	; reguły.
	cmp rdx, ASCII_NEWLINE
	je .parse_new_rule

	; Sprawdzamy poprawność naszego znaku
	cmp rdx, FIRST_VISIBLE_ASCII_CHAR
	jb .exit_fail
	cmp rdx, LAST_VISIBLE_ASCII_CHAR
	ja .exit_fail

	; Przechodzimy do kolejnego znaku i wracamy na początek pętli.
	inc rsi
	jmp .validate_rule_characters_loop

.parse_rules_done:
	; Przygotowujemy się do znajdowania i wypisywania wyjścia.
	; Zapisujemy wskaźnik na bufor wejściowy i jego rozmiar, żeby zwolnić
	; rejestry R12 i R13.
	mov [input_buffer], r12
	mov [input_buffer_size], r13

	; Alokujemy nasz bufor wyjściowy.
	mov eax, SYS_MMAP
	xor edi, edi ; Chcemy, żeby system operacyjny sam wybrał adres naszego
		     ; bufora.
	mov rsi, OUTPUT_BUFFER_SIZE ; Chcemy zaalokować OUTPUT_BUFFER_SIZE 
				    ; bajtów.
	mov edx, PROT_READ | PROT_WRITE ; Flagi dotyczące ochrony obszaru 
					; pamięci, który zaalokujemy.
	mov r10d, MAP_PRIVATE | MAP_ANON ; Chcemy, żeby nasz zaalokowany obszar
					 ; nie mógł zostać użyty przez inne
					 ; procesy.
	mov r8, -1 ; fd = -1
	xor r9, r9 ; offset = 0
	syscall

	; Sprawdzamy czy sys_mmap() zakończył się sukcesem, czy błędem.
	test rax, rax
	js .exit_fail ; Jeżeli zakończył się błędem, 
		      ; kończymy program.
	
	; Zapisujemy w R14 adres zaalokowanego bloku pamięci.
	mov r14, rax

	; Alokujemy (za pomocą sys_mmap) nasz stos, którego będziemy używać w
	; celu uruchomienia algorytmu DFS, który nie używa stosu systemowego.
	mov eax, SYS_MMAP
	xor edi, edi ; Chcemy, żeby system operacyjny sam wybrał adres naszego
		     ; bufora.
	mov rsi, INITIAL_STACK_SIZE ; Chcemy zaalokować INITIAL_STACK_SIZE
				    ; bajtów.
	mov edx, PROT_READ | PROT_WRITE ; Flagi dotyczące ochrony obszaru 
					; pamięci, który zaalokujemy.
	mov r10d, MAP_PRIVATE | MAP_ANON ; Chcemy, żeby nasz zaalokowany obszar
					 ; nie mógł zostać użyty przez inne
					 ; procesy.
	mov r8, -1 ; fd = -1
	xor r9, r9 ; offset = 0
	syscall

	; Sprawdzamy czy nasze wywołanie sys_mmap() zakończyło się sukcesem.
	test rax, rax
	js .exit_fail

	; Zapisujemy adres zaalokowanego bloku pamięci jako bazę stosu.
	mov [stack_base], rax
	mov qword [stack_size], INITIAL_STACK_SIZE

	; Algorytm DFS generujący wyjście.
	; W algorytmie:
	; R8 - wskaźnik na znak, który obecnie rozważamy.
	; R9 - ile iteracji należy jeszcze wykonać.
	; R10 - szczyt stosu.
	; R12 - koniec bloku pamięci zaalokowanego na stos.
	; R13 - wskaźnik na tablicę rules.
	; R14 - wskaźnik na bufor wyjściowy.
	; R15 - ilość bajtów wpisanych do bufora wyjściowego.
	mov r8, [starting_symbol_ptr]
	mov r9, rbx ; RBX przechowuje n, czyli całkowitą ilość iteracji do 
		    ; wykonania.
	mov r10, rax ; RAX w tym momencie nadal przechowuje wskaźnik na bazę
		     ; naszego stosu (a obecnie baza stosu jest jednocześnie
		     ; jego szczytem, bo stos jest pusty).
	
	; Ustawiamy R12 na wskaźnik na koniec zaalokowanego na stos obszaru
	; pamięci (wskaźnik na bazę stosu + początkowy rozmiar stosu).
	mov r12, rax
	add r12, INITIAL_STACK_SIZE

	lea r13, [rules]
	xor r15d, r15d ; Na początku bufor wyjściowy jest pusty dlatego R15 = 0.

.dfs_loop:
	; Pobieramy znak z aktualnego napisu.
	movzx rdx, byte [r8]
	inc r8 ; Przechodzimy do kolejnego znaku.

	; Sprawdzamy, czy nie jesteśmy na końcu obecnego napisu (napisy kończą
	; się NULLem).
	test rdx, rdx
	jz .dfs_pop_or_exit

	; Jeżeli nie zostało więcej iteracji do wykonania, wypisujemy obecny znak.
	test r9, r9
	jz .print_character

	; W przeciwnym przypadku, sprawdzamy czy dla naszego znaku jest 
	; zdefiniowana reguła.
	mov rcx, rdx ; W RCX będzie indeks tablicy reugł odpowiadający regule
		     ; dla naszego znaku.
	
	mov rbx, qword [r13 + rcx * 8] ; Zapisujemy naszą regułę w RBX.
	
	; Nasza reguła jest zdefiniowana wtw. RBX (nasza reguła) != NULL.
	test rbx, rbx
	jz .print_character ; Jeżeli dla naszego znaku nie ma reguły, chcemy
			    ; go po prostu wypisać, bo nigdy się nie zmieni.

	; Wykonujemy "rekurencyjne" wejście w nową regułę.
	; Sprawdzamy czy kolejnym bajtem w obecnym napisie, w którym jesteśmy
	; nie jest NULL. Jeżeli tak jest, nie ma po co zapisywać go na stosie,
	; skoro i tak po powrocie do tego napisu od razu z niego wyjdziemy.
	; Jeżeli tak nie jest, zapisujemy wskaźnik do kolejnego znaku na
	; naszym stosie, by potem móc do niego wrócić.
	movzx ecx, byte [r8] ; Pobieramy kolejny znak.
	test ecx, ecx ; Sprawdzamy czy jest NULLem.
	jz .dfs_enter_rule ; Jeżeli tak, to pomijamy zapisywanie wskaźnika do
			   ; niego na stosie.
	
	; Zapisujemy nasz "return address" (znak, do którego będziemy wracać po
	; przejściu przez nową regułę) oraz pozostałą liczbę iteracji na stos.

	; Najpierw sprawdzamy, czy jest miejsce na naszym stosie.
	lea r11, [r10 + 16] ; R11 to wskaźnik na nowy potencjalny koniec stosu
			    ; (obecny szczyt + 2 quadwordy, jeden na znak, do
			    ; którego będziemy wracać, jeden by zapisać ilość
			    ; iteracji do wykonania).
	cmp r11, r12 ; Porównujemy potencjalny nowy szczyt stosu ze wskaźnikiem
		     ; na koniec obszaru pamięci zaalokowanego na stos, by
		     ; ustalić, czy nasze 2 qwordy się zmieszczą.
	jbe .push_to_stack ; Jeżeli nasze dwa qwordy się zmieszczą, nie
			   ; chcemy powiększać stosu, więc od razu przechodzimy
			   ; do dodawania na niego elementów.
	
	; Nasz stos jest za mały. Musimy go powiększyć.
	; Użyjemy do tego funkcji systemowej sys_mremap.
	mov rdi, [stack_base] ; addr = wskaźnik na bazę naszego stosu.
	sub r10, rdi ; R10 jest teraz równy ilości bajtów znajdujących się
		     ; na stosie (bo wcześniej był równy wskaźnikowi na szczyt,
		     ; więc po odjęciu od niego wskaźnika na bazę otrzymujemy
		     ; rozmiar elementów znajdujących się na stosie).

	push r10 ; Zapisujemy R10, ponieważ będziemy nadpisywać jego wartość
		 ; przy wywoływaniu sys_mremap(). Będziemy go potrzebowali by 
		 ; obliczyć gdzie znajduje się szczyt naszego stosu po 
		 ; realokacji.
	push rdx ; Zapisujemy RDX, żeby po wywołaniu sys_mremap (gdzie w rdx
		 ; jest przekazywany jeden z argumentów), przywrócić jego
		 ; wartość.
	
	; Wywołjemy sys_mremap.
	mov eax, SYS_MREMAP 
	mov rsi, [stack_size] ; old_len = obecny rozmiar stosu.

	; Ustawiamy new_len (RDX) = 2 * obecny rozmiar stosu (RSI).
	mov rdx, rsi
	shl rdx, 1 ; RDX *= 2

	mov r10d, MREMAP_MAYMOVE ; Mówimy systemowi operacyjnemu, że może
				 ; przenieść nasz stos do innego miejsca
				 ; w pamięci.
	syscall

	; Sprawdzamy czy nasze wywołanie sys_mremap zakończyło się sukcesem.
	test rax, rax
	js .exit_fail ; Błąd alokacji.

	; Aktualizujemy R12, by wskazywał na nowy koniec obszaru pamięci
	; przeznaczonego na stos.
	mov r12, rax ; R12 = nowa baza.
	add r12, rdx ; R12 += nowy rozmiar zaalokowanego obszaru pamięci.

	mov [stack_base], rax ; Zapisujemy wskaźnik na nową bazę naszego stosu.
	mov [stack_size], rdx ; Zapisujemy nowy romiar naszego stosu.

	pop rdx ; Przywracamy wartość RDX.
	pop r10 ; Przywracamy wartość R10.

	; Obliczamy nowy szczyt stosu i zapisujemy go w R10.
	; W chwili obecnej R10 jest równy ilości bajtów zapisanych na
	; stosie. Wystarczy więc dodać do niego wskaźnik na nową bazę stosu
	; (RAX) by wskazywał na nowy szczyt.
	add r10, rax
	
.push_to_stack:
	mov [r10], r8 ; Zapisujemy na stos znak, do którego będziemy wracać
		      ; (nasz "return address").
	mov [r10 + 8], r9 ; Zapisujemy ilość iteracji, która została nam do
			  ; wykonania na stos.
	add r10, 16 ; Przesuwamy wskaźnik na szczyt stosu.

.dfs_enter_rule:
	mov r8, rbx ; Nowym łańcuchem, który będziemy parsować, jest adres naszej reguły.
	dec r9 ; Zmniejszamy licznik tego, ile iteracji mamy do wykonania.
	jmp .dfs_loop ; Wracamy na początek pętli
	
.print_character:
	mov byte [r14 + r15], dl ; Pierwsze puste miejsce w naszym buforze
				 ; znajduje się w początek (R14) + ilość 
				 ; zapisanych bajtów (R15). Zapisujemy do
				 ; niego nasz znak, przechowywany w RDX.
	inc r15 ; Zwiększamy naszą pozycję w buforze.

	; Sprawdzamy, czy bufor jest pełny.
	mov r11, OUTPUT_BUFFER_SIZE
	cmp r15, r11 ; Porównujemy ilość bajtów zapisanych do bufora z jego
		     ; rozmiarem.
	jne .dfs_loop ; Jeżeli nasz bufor nie jest jeszcze pełny, nie chcemy
		      ; go wypisywać. Wracamy więc na początek pętli.
	
	; Nasz bufor jest pełny. Wypisujemy go na stdout i "czyścimy".
	mov rsi, r14 ; buf = wskaźnik na początek output_buffer.
	mov rdx, r15 ; count = ilość bajtów zapisanych w buforze.
	mov edi, STDOUT ; fd = STDOUT

.write_loop:
	mov eax, SYS_WRITE ; Będziemy wypisywać za pomocą sys_write().
	syscall

	test rax, rax ; Sprawdzamy, czy sys_write() zakończył się sukcesem.
	js .exit_fail ; Jeżeli nie, wychodzimy z błędem.
	
	; Przestawiamy wskaźnik na początek danych, które będziemy wypisywać
	; o ilość bajtów wypisanych przez sys_write().
	add rsi, rax

	; Odejmujemy od ilości bajtów do wypisania ilość bajtów wypisanych przez sys_write().
	sub rdx, rax

	; Sprawdzamy czy zostało nam coś jeszcze do wypisania. Jeżeli tak,
	; to znaczy, że sys_write() nie wypisał całego naszego bufora, więc
	; musimy wrócić na początek pętli wypisującej. W przeciwnym przypadku,
	; kończymy wypisywanie.
	test rdx, rdx
	jnz .write_loop ; Jeżeli zostało jeszcze coś do wypisania, znowu
		       ; wywołujemy sys_write().

	xor r15d, r15d ; "Czyścimy" nasz bufor - ustawiamy naszą pozycję
		       ; w nim na 0.

	jmp .dfs_loop ; Wracamy na początek głównej pętli.

.dfs_pop_or_exit:
	cmp r10, [stack_base] ; Sprawdzamy, czy jest cokolwiek na naszym stosie.
	je .print_newline_and_exit_success ; Jeżeli nasz stos jest pusty, 
					   ; kończymy algorytm.
	
	; W przeciwnym przypadku, zdejmujemy dwa quadwordy ze stosu.
	; Wyznaczają one ilość iteracji do wykonania oraz znak, do którego mamy
	; wrócić.
	sub r10, 16 ; Cofamy wskaźnik na szczyt stosu o dwa quadwordy w dół.
	mov r8, [r10] ; Wracamy do znaku, do którego wskaźnik znajduje się na
		      ; stosie.
	mov r9, [r10 + 8] ; Przywracamy ilość iteracji, którą należy jeszcze
			  ; wykonać.
	jmp .dfs_loop ; Wracamy na początek pętli.

.print_newline_and_exit_success:
	; Dodajemy znak nowej linii na koniec naszego bufora wyjścia, bo
	; nasze wyjście ma się kończyć znakiem nowej linii.
	mov byte [r14 + r15], ASCII_NEWLINE ; Dopisujemy NEWLINE na pozycji
				       	    ; początek bufora + ilość bajtów
				            ; zapisanych w buforze.
	inc r15 ; Zwiększamy ilość bajtów zapisanych w buforze.

	; Wypisujemy bufor.
	mov edi, STDOUT ; fd = STDOUT
	mov rsi, r14 ; buf = wskaźnik na początek bufora wyjścia.
	mov rdx, r15 ; count = ilość bajtów zapisanych w buforze.

.final_write_loop:
	; Wypisujemy bufor za pomocą sys_write().
	mov eax, SYS_WRITE
	syscall

	; Sprawdzamy czy sys_write() zakończył się sukcesem.
	test rax, rax
	js .exit_fail ; Jeżeli wywołanie systemowe skończyło się błędem,
		      ; kończymy program z błędem.
	
	sub rdx, rax ; Obliczamy ilość bajtów, która została jeszcze do
		     ; wypisania.
	test rdx, rdx
	jz .clean_up_and_exit ; Jeżeli sys_write() wypisał cały nasz bufor,
			      ; chcemy skończyć program.
	
	; sys_write() nie wypisał całego bufora.
	add rsi, rax ; Udało nam się wypisać tyle bajtów, ile zwrócił
		     ; zwróciło sys_write(). Zatem przesuwamy nasz początek
		     ; bufora, żeby nie wypisywać ponownie tych samych znaków.
	jmp .final_write_loop ; Znowu próbujemy wypisać (pozostałe) znaki na
			      ; wyjście.

.exit_fail:
	; exit_code jest domyślnie ustawiony na 0. Jak wychodzimy z błędem,
	; chcemy zwrócić 1.
	mov qword [exit_code], 1

.clean_up_and_exit:
	; Zwalniamy pamięć naszego stosu jeżeli był zaalokowany.
	mov rdi, [stack_base]
	test rdi, rdi ; Sprawdzamy czy alokowaliśmy stos.
	jz .free_output_buffer ; Jeżeli nie, to oczywiście nie chcemy zwalniać
			       ; czegoś, czego nie zaalokowaliśmy.

	; Zwalniamy pamięć stosu.
	mov eax, SYS_MUNMAP
	; addr (rdi) już jest poprawnie ustawiony jako wskaźnik na bazę stosu.
	mov rsi, [stack_size] ; Jako len przekazujemy rozmiar naszego stosu.
	syscall

.free_output_buffer:
	; Zwalniamy pamięć naszego bufora wyjściowego jeżeli był zaalokowany.
	test r14, r14 ; Sprawdzamy, czy alokowaliśmy bufor.
	jz .free_input_buffer ; Jeżeli nie, przechodzimy do zwalniania bufora
			      ; wejściowego.

	; Zwalniamy pamięć bufora wyjściowego.
	mov eax, SYS_MUNMAP
	mov rdi, r14 ; addr = wskaźnik na początek bufora.
	mov rsi, OUTPUT_BUFFER_SIZE ; Jako len przekazujemy rozmiar bufora
				    ; wyjściowego. Nie zmienia się ona podczas
				    ; działanie programu, dlatego przekazujemy
				    ; wartość stałą.
	syscall

.free_input_buffer:
	; Zwalniamy pamięc naszego bufora wejściowego jeżeli był alokowany.
	mov rdi, [input_buffer]
	test rdi, rdi ; Sprawdzamy, czy bufor wejściowy był alokowany.
	jz .exit ; Jeżeli nie był, to nie zostało nam nic do zwolnienia.
		 ; Kończymy program.

	mov eax, SYS_MUNMAP
	; Do RDI (addr) przekazaliśmy już adres naszego bufora.
	mov rsi, [input_buffer_size] ; Jako len przekazujemy rozmiar naszego 
				     ; bufora.
	syscall

.exit:
	; Wywołujemy exit() i zwracamy exit_code.
	mov eax, SYS_EXIT
	mov edi, dword [exit_code]
	syscall
