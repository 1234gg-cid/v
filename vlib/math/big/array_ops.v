module big

import math.util

// Compares the magnitude of the two unsigned integers represented the given
// digit arrays. Returns -1 if a < b, 0 if a == b and +1 if a > b. Here
// a is operand_a and b is operand_b (for brevity).
fn compare_digit_array(operand_a []u32, operand_b []u32) int {
	a_len := operand_a.len
	b_len := operand_b.len
	if a_len != b_len {
		return if a_len < b_len { -1 } else { 1 }
	}
	// They have the same number of digits now
	// Go from the most significant digit to the least significant one
	for index := a_len - 1; index >= 0; index-- {
		a_digit := operand_a[index]
		b_digit := operand_b[index]
		if a_digit != b_digit {
			return if a_digit < b_digit { -1 } else { 1 }
		}
	}
	return 0
}

// Add the digits in operand_a and operand_b and stores the result in sum.
// This function does not perform any allocation and assumes that the storage is
// large enough. It may affect the last element, based on the presence of a carry
fn add_digit_array(operand_a []u32, operand_b []u32, mut sum []u32) {
	// Zero length cases
	if operand_a.len == 0 {
		for index in 0 .. operand_b.len {
			sum[index] = operand_b[index]
		}
	}
	if operand_b.len == 0 {
		for index in 0 .. operand_a.len {
			sum[index] = operand_a[index]
		}
	}

	// First pass intersects with both operands
	smaller_limit := util.imin(operand_a.len, operand_b.len)
	larger_limit := util.imax(operand_a.len, operand_b.len)
	mut a, mut b := if operand_a.len >= operand_b.len {
		operand_a, operand_b
	} else {
		operand_b, operand_a
	}
	mut carry := u64(0)
	for index in 0 .. smaller_limit {
		partial := carry + a[index] + b[index]
		sum[index] = u32(partial)
		carry = u32(partial >> 32)
	}

	for index in smaller_limit .. larger_limit {
		partial := carry + a[index]
		sum[index] = u32(partial)
		carry = u32(partial >> 32)
	}

	if carry == 0 {
		sum.delete_last()
	} else {
		sum[larger_limit] = u32(carry)
	}
}

// Subtracts operand_b from operand_a and stores the difference in storage.
// It assumes operand_a contains the larger "integer" and that storage is
// the same size as operand_a and is 0
fn subtract_digit_array(operand_a []u32, operand_b []u32, mut storage []u32) {
	// Zero length cases
	if operand_a.len == 0 {
		// nothing to subtract from
		return
	}
	if operand_b.len == 0 {
		// nothing to subtract
		for index in 0 .. operand_a.len {
			storage[index] = operand_a[index]
		}
	}

	mut carry := false
	for index in 0 .. operand_b.len {
		mut a_digit := u64(operand_a[index])
		b_digit := operand_b[index] + if carry { u64(1) } else { u64(0) }
		carry = a_digit < b_digit
		if carry {
			a_digit += 0x100000000
		}
		storage[index] = u32(a_digit - b_digit)
	}

	for index in operand_b.len .. operand_a.len {
		mut a_digit := u64(operand_a[index])
		b_digit := if carry { u64(1) } else { u64(0) }
		carry = a_digit < b_digit
		if carry {
			a_digit += 0x100000000
		}
		storage[index] = u32(a_digit - b_digit)
	}

	for storage.len > 0 && storage.last() == 0 {
		storage.delete_last()
	}
}

// Multiplies the unsigned (non-negative) integers represented in a and b and the product is
// stored in storage. It assumes that storage has length equal to the sum of lengths
// of a and b. Length refers to length of array, that is, digit count.
fn multiply_digit_array(operand_a []u32, operand_b []u32, mut storage []u32) {
	for b_index in 0 .. operand_b.len {
		mut carry := u64(0)
		for a_index in 0 .. operand_a.len {
			partial_product := u64(storage[a_index + b_index]) + carry +
				u64(operand_a[a_index]) * u64(operand_b[b_index])
			storage[a_index + b_index] = u32(partial_product)
			carry = partial_product >> 32
		}
		if carry != 0 {
			storage[b_index + operand_a.len] = u32(carry)
		}
	}
	for storage.len > 0 && storage.last() == 0 {
		storage.delete_last()
	}
}

// Stores the product of the unsigned (non-negative) integer represented in a and the digit in value
// in the storage array. It assumes storage is pre-initialised and populated with 0's
fn multiply_array_by_digit(operand_a []u32, value u32, mut storage []u32) {
	if value == 0 {
		for storage.len > 0 {
			storage.delete_last()
		}
		return
	}
	if value == 1 {
		for index in 0 .. operand_a.len {
			storage[index] = operand_a[index]
		}
		for storage.len > 0 && storage.last() == 0 {
			storage.delete_last()
		}
		return
	}
	mut carry := u32(0)
	for index in 0 .. operand_a.len {
		product := u64(operand_a[index]) * value + carry
		storage[index] = u32(product)
		carry = u32(product >> 32)
	}
	if carry > 0 {
		if storage.last() == 0 {
			storage[operand_a.len] = carry
		} else {
			storage << carry
		}
	}
	for storage.len > 0 && storage.last() == 0 {
		storage.delete_last()
	}
}

// Divides the non-negative integer in a by non-negative integer b and store the two results
// in quotient and remainder respectively. It is different from the rest of the functions
// because it assumes that quotient and remainder are empty zero length arrays. They can be
// made to have appropriate capacity though
fn divide_digit_array(operand_a []u32, operand_b []u32, mut quotient []u32, mut remainder []u32) {
	cmp_result := compare_digit_array(operand_a, operand_b)
	// a == b => q, r = 1, 0
	if cmp_result == 0 {
		quotient << 1
		for quotient.len > 1 {
			quotient.delete_last()
		}
		for remainder.len > 0 {
			remainder.delete_last()
		}
		return
	}

	// a < b => q, r = 0, a
	if cmp_result < 0 {
		for quotient.len > 0 {
			quotient.delete_last()
		}
		for index in 0 .. operand_a.len {
			remainder << operand_a[index]
		}
		return
	}
	if operand_b.len == 1 {
		divide_array_by_digit(operand_a, operand_b[0], mut quotient, mut remainder)
	} else {
		divide_array_by_array(operand_a, operand_b, mut quotient, mut remainder)
	}
}

// Performs division on the non-negative dividend in a by the single digit divisor b. It assumes
// quotient and remainder are empty zero length arrays without previous allocation
fn divide_array_by_digit(operand_a []u32, divisor u32, mut quotient []u32, mut remainder []u32) {
	if operand_a.len == 1 {
		// 1 digit for both dividend and divisor
		dividend := operand_a[0]
		q := dividend / divisor
		if q != 0 {
			quotient << q
		}
		rem := dividend % divisor
		if rem != 0 {
			remainder << rem
		}
		return
	}
	// Dividend has more digits
	mut rem := u64(0)
	divisor64 := u64(divisor)
	// Pad quotient to contain sufficient space
	for _ in 0 .. operand_a.len {
		quotient << 0
	}
	// Perform division step by step
	for index := operand_a.len - 1; index >= 0; index-- {
		dividend := (rem << 32) + operand_a[index]
		quotient[index] = u32(dividend / divisor64)
		rem = dividend % divisor64
	}
	// Remove leading zeros from quotient
	for quotient.len > 0 && quotient.last() == 0 {
		quotient.delete_last()
	}
	remainder << u32(rem)
	for remainder.len > 0 && remainder.last() == 0 {
		remainder.delete_last()
	}
}

// Shifts the contents of the original array by the given amount of bits to the left.
// This function assumes that the amount is less than 32. The storage is expected to
// allocated with zeroes.
fn shift_digits_left(original []u32, amount u32, mut storage []u32) {
	mut leftover := u32(0)
	offset := 32 - amount
	for index in 0 .. original.len {
		value := leftover | (original[index] << amount)
		leftover = (original[index] & (u32(-1) << offset)) >> offset
		storage[index] = value
	}
	if leftover != 0 {
		storage << leftover
	}
}

// Shifts the contents of the original array by the given amount of bits to the right.
// This function assumes that the amount is less than 32. The storage is expected to
// be allocated with zeroes.
fn shift_digits_right(original []u32, amount u32, mut storage []u32) {
	mut moveover := u32(0)
	mask := (u32(1) << amount) - 1
	offset := 32 - amount
	for index := original.len - 1; index >= 0; index-- {
		value := (moveover << offset) | (original[index] >> amount)
		moveover = original[index] & mask
		storage[index] = value
	}
	for storage.len > 0 && storage.last() == 0 {
		storage.delete_last()
	}
}

fn bitwise_or_digit_array(operand_a []u32, operand_b []u32, mut storage []u32) {
	lower, upper, bigger := if operand_a.len < operand_b.len {
		operand_a.len, operand_b.len, operand_b
	} else {
		operand_b.len, operand_a.len, operand_a
	}
	for index in 0 .. lower {
		storage[index] = operand_a[index] | operand_b[index]
	}
	for index in lower .. upper {
		storage[index] = bigger[index]
	}
	for storage.len > 0 && storage.last() == 0 {
		storage.delete_last()
	}
}

fn bitwise_and_digit_array(operand_a []u32, operand_b []u32, mut storage []u32) {
	lower := util.imin(operand_a.len, operand_b.len)
	for index in 0 .. lower {
		storage[index] = operand_a[index] & operand_b[index]
	}
	for storage.len > 0 && storage.last() == 0 {
		storage.delete_last()
	}
}

fn bitwise_xor_digit_array(operand_a []u32, operand_b []u32, mut storage []u32) {
	lower, upper, bigger := if operand_a.len < operand_b.len {
		operand_a.len, operand_b.len, operand_b
	} else {
		operand_b.len, operand_a.len, operand_a
	}
	for index in 0 .. lower {
		storage[index] = operand_a[index] ^ operand_b[index]
	}
	for index in lower .. upper {
		storage[index] = bigger[index]
	}
	for storage.len > 0 && storage.last() == 0 {
		storage.delete_last()
	}
}

fn bitwise_not_digit_array(original []u32, mut storage []u32) {
	for index in 0 .. original.len {
		storage[index] = ~original[index]
	}
	for storage.len > 0 && storage.last() == 0 {
		storage.delete_last()
	}
}
