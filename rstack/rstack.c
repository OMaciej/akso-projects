#include "rstack.h"

#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <inttypes.h>

typedef union rstack_store rstack_store_t;
typedef struct rstack_node rstack_node_t;
typedef struct rstack_list rstack_list_t;

// Lista zawierająca wszystkie obecnie istniejące stosy
static rstack_list_t* all_stacks = nullptr;

// Zmienna ta jest używana by w czasie stałym
// ustalać czy dany węzeł był już odwiedzony. Za
// każdym razem, gdy wywołujemy jakąś funkcję która
// będzie odwiedzać węzły/stosy i oznaczać je jako
// odwiedzone, musimy zwiększyć ją o 1.
static unsigned long current_epoch = 0;

union rstack_store {
	rstack_t* stack_val;
	uint64_t int_val;
};

struct rstack_node {
	rstack_store_t value;
	bool stores_int; // czy ten węzeł przechowuje uint64_t,
					 // czy rstack_t*

	rstack_node_t* next_node;
	unsigned long visit_epoch; // używane by ustalić, czy 
							   // odwiedziliśmy już dany węzeł
};

struct rstack_list {
	rstack_t* value;
	rstack_list_t* next;
};

struct rstack {
	rstack_node_t* top;
	bool external_reference_exists; // czy użytkownik ma gdzieś
									// wskażnik do naszego stosu

	bool internal_reference_exists; // czy jakiś stos do którego
									// użytkownik ma wskaźnik zawiera
									// gdzieś odniesienie do naszego
									// stosu
};

// Dodaje stos na początek listy stosów.
// Zwraca true gdy się uda, zaś false w przypadku błędu
static bool add_to_stack_list_front(rstack_list_t** list, 
									rstack_t* element_to_add) {
	rstack_list_t* new_list_element = malloc(sizeof(rstack_list_t));

	if  (new_list_element == nullptr) {
		errno = ENOMEM;
		return false;
	}
	
	new_list_element->value = element_to_add;
	new_list_element->next = *list;
	*list = new_list_element;

	return true;
}

// Rekurencyjna funkcja pomocnicza do rstack_front().
static result_t find_rstack_front(rstack_node_t* node) {
	result_t result;
	result.flag = false;

	if  (node == nullptr) {
		return result;
	}

	// Jeżeli obecny węzeł przechowuje liczbę,
	// znaleźliśmy odpowiedź
	if  (node->stores_int) {
		result.flag = true;
		result.value = node->value.int_val;

		return result;
	}

	// Oznaczamy wierzchołek jako odwiedzony
	node->visit_epoch = current_epoch;

	// Skoro nasz wierzchołek nie zawiera liczby, to zawiera stos.
	// Szukamy więc wartości w tym stosie.
	rstack_node_t* child_node = node->value.stack_val->top;
	if  (child_node != nullptr &&
		child_node->visit_epoch != current_epoch) {
		result = find_rstack_front(node->value.stack_val->top);
	}

	// Skoro nie znaleźliśmy liczby w tym węźle, szukamy jej
	// w następnym
	if  (!result.flag) {
		result = find_rstack_front(node->next_node);
	}

	return result;
}

// Ustawia węzłom zawierającym stosy znajdującym
// się na stosie parent internal_reference_exists na
// true. Oznacza w ten sposób, że węzły te znajdują 
// się pod jakimś stosem, do którego dostęp ma
// użytkownik, więc nie należy ich usuwać.
static void mark_children(rstack_t* parent) {
	rstack_node_t* node = parent->top;

	while  (node != nullptr) {
		if  (!node->stores_int && 
			!node->value.stack_val->internal_reference_exists) {
			node->value.stack_val->internal_reference_exists = true;
			mark_children(node->value.stack_val);
		}

		node = node->next_node;
	}
}

// Znajduje wszystkie stosy, które są elementami stosów
// do których dostęp ma użytkownik.
static void mark_internal_references() {
	rstack_list_t* iter = all_stacks;

	while  (iter != nullptr) {
		iter->value->internal_reference_exists = false;

		iter = iter->next;
	}
	
	iter = all_stacks;

	while  (iter != nullptr) {
		if  (iter->value->external_reference_exists && 
			!iter->value->internal_reference_exists) {
			mark_children(iter->value);
		}

		iter = iter->next;
	}
}

// Zwalnia stos z pamięci
static void free_stack(rstack_t* stack) {
	if  (stack == nullptr) {
		return;
	}

	// Zanim możemy zwolnić stos, musimy 
	// zwolnić wszystkie jego węzły
	rstack_node_t* node = stack->top;

	while  (node != nullptr) {
		rstack_node_t* next = node->next_node;
		free(node);
		node = next;
	}

	free(stack);
}

// Zwalnia z pamięci wszystkie stosy, które
// nie będą już potrzebne - tzn. użytkownik nie
// ma już do nich bezpośredniego dostępu i nie
// znajdują się na żadnych stosach, do których ma.
static void delete_unreferenced_stacks() {
	rstack_list_t* previous = nullptr;
	rstack_list_t* iter = all_stacks;

	while  (iter != nullptr) {
		rstack_list_t* next = iter->next;

		if  (!iter->value->external_reference_exists &&
			 !iter->value->internal_reference_exists) {
				if  (previous != nullptr) {
					previous->next = next;
				} else {
					all_stacks = all_stacks->next;
				}

				free_stack(iter->value);
				free(iter);
		} else {
			previous = iter;
		}

		iter = next;
	}
}

// Pomocnicza funkcja do rstack_empty, która
// rekurencyjnie sprawdza czy z węzła node można
// dojść do jakiegoś węzła zawierającego liczbę.
static bool check_if_empty(rstack_node_t* node) {
	if  (node == nullptr) {
		return true;
	}
	
	// Oznaczamy wierzchołek jako odwiedzony
	node->visit_epoch = current_epoch;

	// Znaleźliśmy liczbę.
	if  (node->stores_int) {
		return false;
	}

	// Sprawdzamy stos zawarty na naszym węźle.
	// Jeżeli jest on pusty, sprawdzamy kolejny węzeł.
	bool is_empty = true;
	rstack_node_t* child_node = node->value.stack_val->top;

	if  (child_node != nullptr && 
		child_node->visit_epoch != current_epoch) {
		is_empty = check_if_empty(child_node);
	}

	if  (is_empty && node->next_node != nullptr) {
		is_empty = check_if_empty(node->next_node);
	}

	return is_empty;
}

// Funkcja pomocnicza do rstack_write(), która
// rekurencyjnie zapisuje węzeł node i wszystkie 
// węzły do których można z niego dojść do pliku.
// interrupted przyjmuje wartość true gdy trafiliśmy
// na cykl i mamy przerwać zapis do pliku.
static bool save_node_to_file(FILE* file, 
							rstack_node_t* node, 
							bool* interrupted) {
	if  (file == nullptr) {
		errno = EINVAL;
		return false;
	}

	if  (node == nullptr || *interrupted) {
		return true;
	}

	// Najpierw chcemy zapisać następny węzeł
	bool saved_next_successfully = save_node_to_file(file, 
		node->next_node, interrupted);
		
	if  (!saved_next_successfully) {
		return false;
	}

	if  (*interrupted) {
		return true;
	}

	// Jeżeli nasz węzeł zawiera liczbę, zapisujemy ją do pliku.
	// W przeciwnym wypadku, chcemy rekurencyjnie zapisać
	// stos, który zawiera nasz węzeł.
	if  (node->stores_int) {
		fprintf(file, "%" PRIu64 "\n", node->value.int_val);

		if  (ferror(file)) {
			return false;
		}

		return true;
	} else {
		rstack_node_t* child_node = node->value.stack_val->top;

		if  (child_node != nullptr) {
			if  (child_node->visit_epoch != current_epoch) {
				child_node->visit_epoch = current_epoch;
				bool saved_child_successfully = save_node_to_file(file, 
					child_node, interrupted);

				// Chcemy wyczyścić visit_epoch naszego "potomka", bo
				// ponowne wejście do niego wcale nie będzie oznaczało
				// że powstał cykl.
				child_node->visit_epoch = 0;

				return saved_child_successfully;
				
			} else {
				*interrupted = true;
				return true;
			}
		}

		return true;
	}
}


rstack_t* rstack_new() {
	rstack_t* new_stack = malloc(sizeof(rstack_t));
	
	if  (new_stack == nullptr) {
		errno = ENOMEM;
		return nullptr;
	}

	new_stack->top = nullptr;
	new_stack->internal_reference_exists = false;
	new_stack->external_reference_exists = true;

	bool error = !add_to_stack_list_front(&all_stacks, new_stack);

	if  (error) {
		free(new_stack);
		return nullptr;
	}

	return new_stack;
}

bool rstack_empty(rstack_t* rs) {
	if  (rs == nullptr) {
		return true;
	}

	current_epoch++;
	bool is_empty = check_if_empty(rs->top);

	return is_empty;
}

result_t rstack_front(rstack_t* rs) {
	if  (rs == nullptr) {
		result_t result;
		result.flag = false;

		return result;
	}

	current_epoch++;
	result_t front = find_rstack_front(rs->top);

	return front;
}

void rstack_delete(rstack_t *rs) {
	if  (rs == nullptr) {
		return;
	}

	// Oznaczamy, że użytkownik nie ma już
	// wskaźnika do naszego stosu
	rs->external_reference_exists = false;

	// Sprawdzamy, jakie stosy należy usunąć.
	mark_internal_references();

	// Usuwamy niepotrzebne już stosy.
	delete_unreferenced_stacks();
}

void rstack_pop(rstack_t *rs) {
	if  (rs == nullptr || rs->top == nullptr) {
		return;
	}

	bool was_top_a_stack = !rs->top->stores_int;
	rstack_node_t* old_node = rs->top;
	rs->top = rs->top->next_node;

	free(old_node);

	// Jeżeli górna szego stosu była innym
	// stosem, musimy sprawdzić czy nie musimy
	// teraz zwolnić jakiś stosów.
	if  (was_top_a_stack) {
		mark_internal_references();
		delete_unreferenced_stacks();
	}
}

int rstack_push_rstack(rstack_t* rs1, rstack_t* rs2) {
	if  (rs1 == nullptr || rs2 == nullptr) {
		errno = EINVAL;
		return -1;
	}

	rstack_node_t* new_node = malloc(sizeof(rstack_node_t));

	if  (new_node == nullptr) {
		errno = ENOMEM;
		return -1;
	}

	new_node->stores_int = false;
	new_node->value.stack_val = rs2;
	new_node->next_node = rs1->top;
	new_node->visit_epoch = 0;

	rs1->top = new_node;

	rs2->internal_reference_exists = true;

	return 0;
}

int rstack_push_value(rstack_t* rs, uint64_t value) {
	if  (rs == nullptr) {
		errno = EINVAL;
		return -1;
	}

	rstack_node_t* new_node = malloc(sizeof(rstack_node_t));

	if  (new_node == nullptr) {
		errno = ENOMEM;
		return -1;
	}

	new_node->stores_int = true;
	new_node->value.int_val = value;
	new_node->next_node = rs->top;
	new_node->visit_epoch = 0;

	rs->top = new_node;

	return 0;
}

rstack_t* rstack_read(const char* path) {
	if  (path == nullptr) {
		errno = EINVAL;
		return nullptr;
	}

	FILE* input_file = fopen(path, "r");

	if  (input_file == nullptr) {
		return nullptr;
	}

	rstack_t* saved_stack = rstack_new();

	if  (saved_stack == nullptr) {
		goto read_error;
	}

	uint64_t value = 0;
	char buffer[32];
	char* end_ptr;

	while  (fscanf(input_file, "%31s", buffer) == 1) {
		errno = 0;

		// Liczby ujemne nie są dozwolone
		if  (buffer[0] == '-') {
			errno = EINVAL;
			goto read_error;
		}

		value = strtoull(buffer, &end_ptr, 10);

		// Jeżeli end_ptr nie wskazuje na null,
		// to znaczy, fscanf() oprócz liczby
		// odczytał też jakieś śmieciowe dane.
		// Uznajemy więc, że dane z podanego pliku
		// są nieprawidłowe i zwracamy błąd
		if  (*end_ptr != '\0') {
			errno = EINVAL;
			goto read_error;
		}

		// Sprawdzamy czy zapisana liczba nie
		// wychodzi poza zakres naszego typu
		if  (errno == ERANGE) {
			goto read_error;
		}

		int result = rstack_push_value(saved_stack, value);

		if  (ferror(input_file) || result == -1) {
			goto read_error;
		}
	}

	if  (ferror(input_file)) {
		goto read_error;
	}

	fclose(input_file);

	return saved_stack;

read_error:
	fclose(input_file);
	rstack_delete(saved_stack);

	return nullptr;
}

int rstack_write(const char* path, rstack_t* rs) {
	if  (path == nullptr || rs == nullptr) {
		errno = EINVAL;
		return -1;
	}

	FILE* output_file = fopen(path, "w");

	if  (output_file == nullptr) {
		return -1;
	}

	// Wartość tej zmiennej odczytuje i ustawia
	// save_node_to_file() by poradzić sobie z
	// przerywaniem zapisu przy napotkaniu cyklu.
	bool interrupted = false;

	current_epoch++;

	if  (rs->top != nullptr) {
		// Oznaczamy korzeń jako odwiedzony
		rs->top->visit_epoch = current_epoch;
	}

	bool error = !save_node_to_file(output_file, rs->top, &interrupted);

	if  (error) {
		fclose(output_file);
		return -1;
	}

	fclose(output_file);
	return 0;
}