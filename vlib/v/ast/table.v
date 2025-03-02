// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module ast

import v.cflag
import v.token
import v.util

[heap]
pub struct Table {
pub mut:
	type_symbols       []TypeSymbol
	type_idxs          map[string]int
	fns                map[string]Fn
	iface_types        map[string][]Type
	dumps              map[int]string // needed for efficiently generating all _v_dump_expr_TNAME() functions
	imports            []string       // List of all imports
	modules            []string       // Topologically sorted list of all modules registered by the application
	global_scope       &Scope
	cflags             []cflag.CFlag
	redefined_fns      []string
	fn_generic_types   map[string][][]Type // for generic functions
	interfaces         map[int]InterfaceDecl
	cmod_prefix        string // needed for ast.type_to_str(Type) while vfmt; contains `os.`
	is_fmt             bool
	used_fns           map[string]bool // filled in by the checker, when pref.skip_unused = true;
	used_consts        map[string]bool // filled in by the checker, when pref.skip_unused = true;
	used_globals       map[string]bool // filled in by the checker, when pref.skip_unused = true;
	used_vweb_types    []Type // vweb context types, filled in by checker, when pref.skip_unused = true;
	used_maps          int    // how many times maps were used, filled in by checker, when pref.skip_unused = true;
	panic_handler      FnPanicHandler = default_table_panic_handler
	panic_userdata     voidptr        = voidptr(0) // can be used to pass arbitrary data to panic_handler;
	panic_npanics      int
	cur_fn             &FnDecl = 0 // previously stored in Checker.cur_fn and Gen.cur_fn
	cur_concrete_types []Type  // current concrete types, e.g. <int, string>
	gostmts            int     // how many `go` statements there were in the parsed files.
	enum_decls         map[string]EnumDecl
	// When table.gostmts > 0, __VTHREADS__ is defined, which can be checked with `$if threads {`
}

// used by vls to avoid leaks
// TODO remove manual memory management
[unsafe]
pub fn (t &Table) free() {
	unsafe {
		t.type_symbols.free()
		t.type_idxs.free()
		t.fns.free()
		t.dumps.free()
		t.imports.free()
		t.modules.free()
		t.cflags.free()
		t.redefined_fns.free()
		t.fn_generic_types.free()
		t.cmod_prefix.free()
		t.used_fns.free()
		t.used_consts.free()
		t.used_globals.free()
		t.used_vweb_types.free()
	}
}

pub type FnPanicHandler = fn (&Table, string)

fn default_table_panic_handler(t &Table, message string) {
	panic(message)
}

pub fn (t &Table) panic(message string) {
	mut mt := unsafe { &Table(t) }
	mt.panic_npanics++
	t.panic_handler(t, message)
}

pub struct Fn {
pub:
	is_variadic     bool
	language        Language
	is_pub          bool
	is_deprecated   bool // `[deprecated] fn abc(){}`
	is_noreturn     bool // `[noreturn] fn abc(){}`
	is_unsafe       bool // `[unsafe] fn abc(){}`
	is_placeholder  bool
	is_main         bool // `fn main(){}`
	is_test         bool // `fn test_abc(){}`
	is_keep_alive   bool // passed memory must not be freed (by GC) before function returns
	no_body         bool // a pure declaration like `fn abc(x int)`; used in .vh files, C./JS. fns.
	mod             string
	file_mode       Language
	pos             token.Position
	return_type_pos token.Position
pub mut:
	return_type Type
	name        string
	params      []Param
	source_fn   voidptr // set in the checker, while processing fn declarations
	usages      int
	//
	generic_names  []string
	attrs          []Attr // all fn attributes
	is_conditional bool   // true for `[if abc]fn(){}`
	ctdefine_idx   int    // the index of the attribute, containing the compile time define [if mytag]
}

fn (f &Fn) method_equals(o &Fn) bool {
	return f.params[1..].equals(o.params[1..]) && f.return_type == o.return_type
		&& f.is_variadic == o.is_variadic && f.language == o.language
		&& f.generic_names == o.generic_names && f.is_pub == o.is_pub && f.mod == o.mod
		&& f.name == o.name
}

pub struct Param {
pub:
	pos         token.Position
	name        string
	is_mut      bool
	is_auto_rec bool
	type_pos    token.Position
	is_hidden   bool // interface first arg
pub mut:
	typ Type
}

pub fn (f &Fn) new_method_with_receiver_type(new_type Type) Fn {
	unsafe {
		mut new_method := f
		new_method.params = f.params.clone()
		for i in 1 .. new_method.params.len {
			if new_method.params[i].typ == new_method.params[0].typ {
				new_method.params[i].typ = new_type
			}
		}
		new_method.params[0].typ = new_type

		return *new_method
	}
}

pub fn (f &FnDecl) new_method_with_receiver_type(new_type Type) FnDecl {
	unsafe {
		mut new_method := f
		new_method.params = f.params.clone()
		for i in 1 .. new_method.params.len {
			if new_method.params[i].typ == new_method.params[0].typ {
				new_method.params[i].typ = new_type
			}
		}
		new_method.params[0].typ = new_type
		return *new_method
	}
}

fn (p &Param) equals(o &Param) bool {
	return p.name == o.name && p.is_mut == o.is_mut && p.typ == o.typ && p.is_hidden == o.is_hidden
}

fn (p []Param) equals(o []Param) bool {
	if p.len != o.len {
		return false
	}
	for i in 0 .. p.len {
		if !p[i].equals(o[i]) {
			return false
		}
	}
	return true
}

/*
pub struct Var {
pub:
	name   string
	is_mut bool
mut:
	typ Type
}
*/

pub fn new_table() &Table {
	mut t := &Table{
		type_symbols: []TypeSymbol{cap: 64000}
		global_scope: &Scope{
			parent: 0
		}
		cur_fn: 0
	}
	t.register_builtin_type_symbols()
	t.is_fmt = true
	set_global_table(t)
	return t
}

const global_table = &Table(0)

pub fn set_global_table(t &Table) {
	unsafe {
		mut pg := &ast.global_table
		*pg = t
	}
}

// used to compare fn's & for naming anon fn's
pub fn (t &Table) fn_type_signature(f &Fn) string {
	mut sig := ''
	for i, arg in f.params {
		// TODO: for now ignore mut/pts in sig for now
		typ := arg.typ.set_nr_muls(0)
		arg_type_sym := t.get_type_symbol(typ)
		sig += arg_type_sym.str().to_lower().replace_each(['.', '__', '&', '', '[]', 'arr_', 'chan ',
			'chan_', 'map[', 'map_of_', ']', '_to_', '<', '_T_', ',', '_', ' ', '', '>', ''])
		if i < f.params.len - 1 {
			sig += '_'
		}
	}
	if f.return_type != 0 && f.return_type != void_type {
		sym := t.get_type_symbol(f.return_type)
		opt := if f.return_type.has_flag(.optional) { 'option_' } else { '' }
		sig += '__$opt$sym.kind'
	}
	return sig
}

// source_signature generates the signature of a function which looks like in the V source
pub fn (t &Table) fn_type_source_signature(f &Fn) string {
	mut sig := '('
	for i, arg in f.params {
		if arg.is_mut {
			sig += 'mut '
		}
		// NB: arg name is only added for fmt, else it would causes errors with generics
		if t.is_fmt && arg.name.len > 0 {
			sig += '$arg.name '
		}
		arg_type_sym := t.get_type_symbol(arg.typ)
		sig += arg_type_sym.name
		if i < f.params.len - 1 {
			sig += ', '
		}
	}
	sig += ')'
	if f.return_type == ovoid_type {
		sig += ' ?'
	} else if f.return_type != void_type {
		return_type_sym := t.get_type_symbol(f.return_type)
		if f.return_type.has_flag(.optional) {
			sig += ' ?$return_type_sym.name'
		} else {
			sig += ' $return_type_sym.name'
		}
	}
	return sig
}

pub fn (t &Table) is_same_method(f &Fn, func &Fn) string {
	if f.return_type != func.return_type {
		s := t.type_to_str(f.return_type)
		return 'expected return type `$s`'
	}
	if f.params.len != func.params.len {
		return 'expected $f.params.len parameter(s), not $func.params.len'
	}
	for i in 1 .. f.params.len {
		if f.params[i].typ != func.params[i].typ {
			exps := t.type_to_str(f.params[i].typ)
			gots := t.type_to_str(func.params[i].typ)
			return 'expected `$exps`, not `$gots` for parameter $i'
		}
	}
	return ''
}

pub fn (t &Table) find_fn(name string) ?Fn {
	if f := t.fns[name] {
		return f
	}
	return none
}

pub fn (t &Table) known_fn(name string) bool {
	t.find_fn(name) or { return false }
	return true
}

pub fn (mut t Table) register_fn(new_fn Fn) {
	// println('reg fn $new_fn.name nr_args=$new_fn.args.len')
	t.fns[new_fn.name] = new_fn
}

pub fn (mut t Table) register_interface(idecl InterfaceDecl) {
	t.interfaces[idecl.typ] = idecl
}

pub fn (mut t TypeSymbol) register_method(new_fn Fn) int {
	// returns a method index, stored in the ast.FnDecl
	// for faster lookup in the checker's fn_decl method
	// println('reg me $new_fn.name nr_args=$new_fn.args.len')
	t.methods << new_fn
	return t.methods.len - 1
}

pub fn (t &Table) register_aggregate_method(mut sym TypeSymbol, name string) ?Fn {
	if sym.kind != .aggregate {
		t.panic('Unexpected type symbol: $sym.kind')
	}
	agg_info := sym.info as Aggregate
	// an aggregate always has at least 2 types
	mut found_once := false
	mut new_fn := Fn{}
	for typ in agg_info.types {
		ts := t.get_type_symbol(typ)
		if type_method := ts.find_method(name) {
			if !found_once {
				found_once = true
				new_fn = type_method
			} else if !new_fn.method_equals(type_method) {
				return error('method `${t.type_to_str(typ)}.$name` signature is different')
			}
		} else {
			return error('unknown method: `${t.type_to_str(typ)}.$name`')
		}
	}
	// register the method in the aggregate, so lookup is faster next time
	sym.register_method(new_fn)
	return new_fn
}

pub fn (t &Table) type_has_method(s &TypeSymbol, name string) bool {
	// println('type_has_method($s.name, $name) types.len=$t.types.len s.parent_idx=$s.parent_idx')
	if _ := t.type_find_method(s, name) {
		return true
	}
	return false
}

// type_find_method searches from current type up through each parent looking for method
pub fn (t &Table) type_find_method(s &TypeSymbol, name string) ?Fn {
	// println('type_find_method($s.name, $name) types.len=$t.types.len s.parent_idx=$s.parent_idx')
	mut ts := unsafe { s }
	for {
		if method := ts.find_method(name) {
			return method
		}
		if ts.kind == .aggregate {
			return t.register_aggregate_method(mut ts, name)
		}
		if ts.parent_idx == 0 {
			break
		}
		ts = unsafe { &t.type_symbols[ts.parent_idx] }
	}
	return none
}

pub struct GetEmbedsOptions {
	preceding []Type
}

// get_embeds returns all nested embedded structs
// the hierarchy of embeds is returned as a list
pub fn (t &Table) get_embeds(sym &TypeSymbol, options GetEmbedsOptions) [][]Type {
	mut embeds := [][]Type{}
	if sym.info is Struct {
		for embed in sym.info.embeds {
			embed_sym := t.get_type_symbol(embed)
			mut preceding := options.preceding
			preceding << embed
			embeds << t.get_embeds(embed_sym, preceding: preceding)
		}
		if sym.info.embeds.len == 0 && options.preceding.len > 0 {
			embeds << options.preceding
		}
	}
	return embeds
}

pub fn (t &Table) type_find_method_from_embeds(sym &TypeSymbol, method_name string) ?(Fn, Type) {
	if sym.info is Struct {
		mut found_methods := []Fn{}
		mut embed_of_found_methods := []Type{}
		for embed in sym.info.embeds {
			embed_sym := t.get_type_symbol(embed)
			if m := t.type_find_method(embed_sym, method_name) {
				found_methods << m
				embed_of_found_methods << embed
			}
		}
		if found_methods.len == 1 {
			return found_methods[0], embed_of_found_methods[0]
		} else if found_methods.len > 1 {
			return error('ambiguous method `$method_name`')
		}
	} else if sym.info is Aggregate {
		for typ in sym.info.types {
			agg_sym := t.get_type_symbol(typ)
			method, embed_type := t.type_find_method_from_embeds(agg_sym, method_name) or {
				return err
			}
			if embed_type != 0 {
				return method, embed_type
			}
		}
	}
	return none
}

fn (t &Table) register_aggregate_field(mut sym TypeSymbol, name string) ?StructField {
	if sym.kind != .aggregate {
		t.panic('Unexpected type symbol: $sym.kind')
	}
	mut agg_info := sym.info as Aggregate
	// an aggregate always has at least 2 types
	mut found_once := false
	mut new_field := StructField{}
	for typ in agg_info.types {
		ts := t.get_type_symbol(typ)
		if type_field := t.find_field(ts, name) {
			if !found_once {
				found_once = true
				new_field = type_field
			} else if new_field.typ != type_field.typ {
				return error('field `${t.type_to_str(typ)}.$name` type is different')
			}
			new_field = StructField{
				...new_field
				is_mut: new_field.is_mut && type_field.is_mut
				is_pub: new_field.is_pub && type_field.is_pub
			}
		} else {
			return error('type `${t.type_to_str(typ)}` has no field or method `$name`')
		}
	}
	agg_info.fields << new_field
	return new_field
}

pub fn (t &Table) struct_has_field(struct_ &TypeSymbol, name string) bool {
	// println('struct_has_field($s.name, $name) types.len=$t.types.len s.parent_idx=$s.parent_idx')
	if _ := t.find_field(struct_, name) {
		return true
	}
	return false
}

// struct_fields returns all fields including fields from embeds
// use this instead symbol.info.fields to get all fields
pub fn (t &Table) struct_fields(sym &TypeSymbol) []StructField {
	mut fields := []StructField{}
	if sym.info is Struct {
		fields << sym.info.fields
		for embed in sym.info.embeds {
			embed_sym := t.get_type_symbol(embed)
			fields << t.struct_fields(embed_sym)
		}
	}
	return fields
}

// search from current type up through each parent looking for field
pub fn (t &Table) find_field(s &TypeSymbol, name string) ?StructField {
	// println('find_field($s.name, $name) types.len=$t.types.len s.parent_idx=$s.parent_idx')
	mut ts := unsafe { s }
	for {
		match mut ts.info {
			Struct {
				if field := ts.info.find_field(name) {
					return field
				}
			}
			Aggregate {
				if field := ts.info.find_field(name) {
					return field
				}
				field := t.register_aggregate_field(mut ts, name) or { return err }
				return field
			}
			Interface {
				if field := ts.info.find_field(name) {
					return field
				}
			}
			SumType {
				t.resolve_common_sumtype_fields(ts)
				if field := ts.info.find_field(name) {
					return field
				}
				return error('field `$name` does not exist or have the same type in all sumtype variants')
			}
			else {}
		}
		if ts.parent_idx == 0 {
			break
		}
		ts = unsafe { &t.type_symbols[ts.parent_idx] }
	}
	return none
}

// find_field_from_embeds is the same as find_field_from_embeds but also looks into nested embeds
pub fn (t &Table) find_field_from_embeds_recursive(sym &TypeSymbol, field_name string) ?(StructField, []Type) {
	if sym.info is Struct {
		mut found_fields := []StructField{}
		mut embeds_of_found_fields := [][]Type{}
		for embed in sym.info.embeds {
			embed_sym := t.get_type_symbol(embed)
			if field := t.find_field(embed_sym, field_name) {
				found_fields << field
				embeds_of_found_fields << [embed]
			} else {
				field, types := t.find_field_from_embeds_recursive(embed_sym, field_name) or {
					StructField{}, []Type{}
				}
				found_fields << field
				embeds_of_found_fields << types
			}
		}
		if found_fields.len == 1 {
			return found_fields[0], embeds_of_found_fields[0]
		} else if found_fields.len > 1 {
			return error('ambiguous field `$field_name`')
		}
	} else if sym.info is Aggregate {
		for typ in sym.info.types {
			agg_sym := t.get_type_symbol(typ)
			field, embed_types := t.find_field_from_embeds_recursive(agg_sym, field_name) or {
				return err
			}
			if embed_types.len > 0 {
				return field, embed_types
			}
		}
	}
	return none
}

// find_field_from_embeds finds and returns a field in the embeddings of a struct and the embedding type
pub fn (t &Table) find_field_from_embeds(sym &TypeSymbol, field_name string) ?(StructField, Type) {
	if sym.info is Struct {
		mut found_fields := []StructField{}
		mut embed_of_found_fields := []Type{}
		for embed in sym.info.embeds {
			embed_sym := t.get_type_symbol(embed)
			if field := t.find_field(embed_sym, field_name) {
				found_fields << field
				embed_of_found_fields << embed
			}
		}
		if found_fields.len == 1 {
			return found_fields[0], embed_of_found_fields[0]
		} else if found_fields.len > 1 {
			return error('ambiguous field `$field_name`')
		}
	} else if sym.info is Aggregate {
		for typ in sym.info.types {
			agg_sym := t.get_type_symbol(typ)
			field, embed_type := t.find_field_from_embeds(agg_sym, field_name) or { return err }
			if embed_type != 0 {
				return field, embed_type
			}
		}
	}
	return none
}

// find_field_with_embeds searches for a given field, also looking through embedded fields
pub fn (t &Table) find_field_with_embeds(sym &TypeSymbol, field_name string) ?StructField {
	if field := t.find_field(sym, field_name) {
		return field
	} else {
		// look for embedded field
		first_err := err
		field, _ := t.find_field_from_embeds(sym, field_name) or { return first_err }
		return field
	}
}

pub fn (t &Table) resolve_common_sumtype_fields(sym_ &TypeSymbol) {
	mut sym := unsafe { sym_ }
	mut info := sym.info as SumType
	if info.found_fields {
		return
	}
	mut field_map := map[string]StructField{}
	mut field_usages := map[string]int{}
	for variant in info.variants {
		mut v_sym := t.get_type_symbol(variant)
		fields := match mut v_sym.info {
			Struct {
				t.struct_fields(v_sym)
			}
			SumType {
				t.resolve_common_sumtype_fields(v_sym)
				v_sym.info.fields
			}
			else {
				[]StructField{}
			}
		}
		for field in fields {
			if field.name !in field_map {
				field_map[field.name] = field
				field_usages[field.name]++
			} else if field.equals(field_map[field.name]) {
				field_usages[field.name]++
			}
		}
	}
	for field, nr_definitions in field_usages {
		if nr_definitions == info.variants.len {
			info.fields << field_map[field]
		}
	}
	info.found_fields = true
	sym.info = info
}

[inline]
pub fn (t &Table) find_type_idx(name string) int {
	return t.type_idxs[name]
}

[inline]
pub fn (t &Table) find_type(name string) ?TypeSymbol {
	idx := t.type_idxs[name]
	if idx > 0 {
		return t.type_symbols[idx]
	}
	return none
}

pub const invalid_type_symbol = &TypeSymbol{
	parent_idx: -1
	language: .v
	mod: 'builtin'
	kind: .placeholder
	name: 'InvalidType'
	cname: 'InvalidType'
}

[inline]
pub fn (t &Table) get_type_symbol(typ Type) &TypeSymbol {
	idx := typ.idx()
	if idx > 0 {
		return unsafe { &t.type_symbols[idx] }
	}
	// this should never happen
	t.panic('get_type_symbol: invalid type (typ=$typ idx=$idx). Compiler bug. This should never happen. Please report the bug using `v bug file.v`.
')
	return ast.invalid_type_symbol
}

// get_final_type_symbol follows aliases until it gets to a "real" Type
[inline]
pub fn (t &Table) get_final_type_symbol(typ Type) &TypeSymbol {
	mut idx := typ.idx()
	if idx > 0 {
		current_type := t.type_symbols[idx]
		if current_type.kind == .alias {
			idx = (current_type.info as Alias).parent_type.idx()
		}
		return unsafe { &t.type_symbols[idx] }
	}
	// this should never happen
	t.panic('get_final_type_symbol: invalid type (typ=$typ idx=$idx). Compiler bug. This should never happen. Please report the bug using `v bug file.v`.')
	return ast.invalid_type_symbol
}

[inline]
pub fn (t &Table) get_type_name(typ Type) string {
	typ_sym := t.get_type_symbol(typ)
	return typ_sym.name
}

[inline]
pub fn (t &Table) unalias_num_type(typ Type) Type {
	sym := t.get_type_symbol(typ)
	if sym.kind == .alias {
		pt := (sym.info as Alias).parent_type
		if pt <= f64_type && pt >= void_type {
			return pt
		}
	}
	return typ
}

fn (mut t Table) check_for_already_registered_symbol(typ TypeSymbol, existing_idx int) int {
	ex_type := t.type_symbols[existing_idx]
	match ex_type.kind {
		.placeholder {
			// override placeholder
			// println('overriding type placeholder `$typ.name`')
			t.type_symbols[existing_idx] = TypeSymbol{
				...typ
				methods: ex_type.methods
			}
			return existing_idx
		}
		else {
			// builtin
			// this will override the already registered builtin types
			// with the actual v struct declaration in the source
			if (existing_idx >= string_type_idx && existing_idx <= map_type_idx)
				|| existing_idx == error_type_idx {
				if existing_idx == string_type_idx {
					// existing_type := t.type_symbols[existing_idx]
					t.type_symbols[existing_idx] = TypeSymbol{
						...typ
						kind: ex_type.kind
					}
				} else {
					t.type_symbols[existing_idx] = typ
				}
				return existing_idx
			}
			return -1
		}
	}
	return -2
}

[inline]
pub fn (mut t Table) register_type_symbol(typ TypeSymbol) int {
	mut typ_idx := -2
	mut existing_idx := t.type_idxs[typ.name]
	if existing_idx > 0 {
		typ_idx = t.check_for_already_registered_symbol(typ, existing_idx)
		if typ_idx != -2 {
			return typ_idx
		}
	}
	if typ.mod == 'main' {
		existing_idx = t.type_idxs[typ.name.trim_prefix('main.')]
		if existing_idx > 0 {
			typ_idx = t.check_for_already_registered_symbol(typ, existing_idx)
			if typ_idx != -2 {
				return typ_idx
			}
		}
	}
	typ_idx = t.type_symbols.len
	t.type_symbols << typ
	t.type_symbols[typ_idx].idx = typ_idx
	t.type_idxs[typ.name] = typ_idx
	return typ_idx
}

[inline]
pub fn (mut t Table) register_enum_decl(enum_decl EnumDecl) {
	t.enum_decls[enum_decl.name] = enum_decl
}

pub fn (t &Table) known_type(name string) bool {
	return t.find_type_idx(name) != 0
}

pub fn (t &Table) known_type_idx(typ Type) bool {
	if typ == 0 {
		return false
	}
	sym := t.get_type_symbol(typ)
	match sym.kind {
		.placeholder {
			return sym.language != .v || sym.name.starts_with('C.')
		}
		.array {
			return t.known_type_idx((sym.info as Array).elem_type)
		}
		.array_fixed {
			return t.known_type_idx((sym.info as ArrayFixed).elem_type)
		}
		.map {
			info := sym.info as Map
			return t.known_type_idx(info.key_type) && t.known_type_idx(info.value_type)
		}
		else {}
	}
	return true
}

// array_source_name generates the original name for the v source.
// e. g. []int
[inline]
pub fn (t &Table) array_name(elem_type Type) string {
	elem_type_sym := t.get_type_symbol(elem_type)
	ptr := if elem_type.is_ptr() { '&'.repeat(elem_type.nr_muls()) } else { '' }
	return '[]$ptr$elem_type_sym.name'
}

[inline]
pub fn (t &Table) array_cname(elem_type Type) string {
	elem_type_sym := t.get_type_symbol(elem_type)
	mut res := ''
	if elem_type.is_ptr() {
		res = '_ptr'.repeat(elem_type.nr_muls())
	}
	return 'Array_$elem_type_sym.cname' + res
}

// array_fixed_source_name generates the original name for the v source.
// e. g. [16][8]int
[inline]
pub fn (t &Table) array_fixed_name(elem_type Type, size int, size_expr Expr) string {
	elem_type_sym := t.get_type_symbol(elem_type)
	ptr := if elem_type.is_ptr() { '&'.repeat(elem_type.nr_muls()) } else { '' }
	size_str := if size_expr is EmptyExpr || size != 987654321 {
		size.str()
	} else {
		size_expr.str()
	}
	return '[$size_str]$ptr$elem_type_sym.name'
}

[inline]
pub fn (t &Table) array_fixed_cname(elem_type Type, size int) string {
	elem_type_sym := t.get_type_symbol(elem_type)
	mut res := ''
	if elem_type.is_ptr() {
		res = '_ptr$elem_type.nr_muls()'
	}
	return 'Array_fixed_${elem_type_sym.cname}_$size' + res
}

[inline]
pub fn (t &Table) chan_name(elem_type Type, is_mut bool) string {
	elem_type_sym := t.get_type_symbol(elem_type)
	mut ptr := ''
	if is_mut {
		ptr = 'mut '
	} else if elem_type.is_ptr() {
		ptr = '&'
	}
	return 'chan $ptr$elem_type_sym.name'
}

[inline]
pub fn (t &Table) chan_cname(elem_type Type, is_mut bool) string {
	elem_type_sym := t.get_type_symbol(elem_type)
	mut suffix := ''
	if is_mut {
		suffix = '_mut'
	} else if elem_type.is_ptr() {
		suffix = '_ptr'
	}
	return 'chan_$elem_type_sym.cname' + suffix
}

[inline]
pub fn (t &Table) thread_name(return_type Type) string {
	if return_type.idx() == void_type_idx {
		if return_type.has_flag(.optional) {
			return 'thread ?'
		} else {
			return 'thread'
		}
	}
	return_type_sym := t.get_type_symbol(return_type)
	ptr := if return_type.is_ptr() { '&' } else { '' }
	opt := if return_type.has_flag(.optional) { '?' } else { '' }
	return 'thread $opt$ptr$return_type_sym.name'
}

[inline]
pub fn (t &Table) thread_cname(return_type Type) string {
	if return_type == void_type {
		if return_type.has_flag(.optional) {
			return '__v_thread_Option_void'
		} else {
			return '__v_thread'
		}
	}
	return_type_sym := t.get_type_symbol(return_type)
	suffix := if return_type.is_ptr() { '_ptr' } else { '' }
	prefix := if return_type.has_flag(.optional) { 'Option_' } else { '' }
	return '__v_thread_$prefix$return_type_sym.cname$suffix'
}

// map_source_name generates the original name for the v source.
// e. g. map[string]int
[inline]
pub fn (t &Table) map_name(key_type Type, value_type Type) string {
	key_type_sym := t.get_type_symbol(key_type)
	value_type_sym := t.get_type_symbol(value_type)
	ptr := if value_type.is_ptr() { '&' } else { '' }
	return 'map[$key_type_sym.name]$ptr$value_type_sym.name'
}

[inline]
pub fn (t &Table) map_cname(key_type Type, value_type Type) string {
	key_type_sym := t.get_type_symbol(key_type)
	value_type_sym := t.get_type_symbol(value_type)
	suffix := if value_type.is_ptr() { '_ptr' } else { '' }
	return 'Map_${key_type_sym.cname}_$value_type_sym.cname' + suffix
	// return 'map_${value_type_sym.name}' + suffix
}

pub fn (mut t Table) find_or_register_chan(elem_type Type, is_mut bool) int {
	name := t.chan_name(elem_type, is_mut)
	cname := t.chan_cname(elem_type, is_mut)
	// existing
	existing_idx := t.type_idxs[name]
	if existing_idx > 0 {
		return existing_idx
	}
	// register
	chan_typ := TypeSymbol{
		parent_idx: chan_type_idx
		kind: .chan
		name: name
		cname: cname
		info: Chan{
			elem_type: elem_type
			is_mut: is_mut
		}
	}
	return t.register_type_symbol(chan_typ)
}

pub fn (mut t Table) find_or_register_map(key_type Type, value_type Type) int {
	name := t.map_name(key_type, value_type)
	cname := t.map_cname(key_type, value_type)
	// existing
	existing_idx := t.type_idxs[name]
	if existing_idx > 0 {
		return existing_idx
	}
	// register
	map_typ := TypeSymbol{
		parent_idx: map_type_idx
		kind: .map
		name: name
		cname: cname
		info: Map{
			key_type: key_type
			value_type: value_type
		}
	}
	return t.register_type_symbol(map_typ)
}

pub fn (mut t Table) find_or_register_thread(return_type Type) int {
	name := t.thread_name(return_type)
	cname := t.thread_cname(return_type)
	// existing
	existing_idx := t.type_idxs[name]
	if existing_idx > 0 {
		return existing_idx
	}
	// register
	thread_typ := TypeSymbol{
		parent_idx: thread_type_idx
		kind: .thread
		name: name
		cname: cname
		info: Thread{
			return_type: return_type
		}
	}
	return t.register_type_symbol(thread_typ)
}

pub fn (mut t Table) find_or_register_array(elem_type Type) int {
	name := t.array_name(elem_type)
	// existing
	existing_idx := t.type_idxs[name]
	if existing_idx > 0 {
		return existing_idx
	}
	cname := t.array_cname(elem_type)
	// register
	array_type_ := TypeSymbol{
		parent_idx: array_type_idx
		kind: .array
		name: name
		cname: cname
		info: Array{
			nr_dims: 1
			elem_type: elem_type
		}
	}
	return t.register_type_symbol(array_type_)
}

pub fn (mut t Table) find_or_register_array_with_dims(elem_type Type, nr_dims int) int {
	if nr_dims == 1 {
		return t.find_or_register_array(elem_type)
	}
	return t.find_or_register_array(t.find_or_register_array_with_dims(elem_type, nr_dims - 1))
}

pub fn (mut t Table) find_or_register_array_fixed(elem_type Type, size int, size_expr Expr) int {
	name := t.array_fixed_name(elem_type, size, size_expr)
	// existing
	existing_idx := t.type_idxs[name]
	if existing_idx > 0 {
		return existing_idx
	}
	cname := t.array_fixed_cname(elem_type, size)
	// register
	array_fixed_type := TypeSymbol{
		kind: .array_fixed
		name: name
		cname: cname
		info: ArrayFixed{
			elem_type: elem_type
			size: size
			size_expr: size_expr
		}
	}
	return t.register_type_symbol(array_fixed_type)
}

pub fn (mut t Table) find_or_register_multi_return(mr_typs []Type) int {
	mut name := '('
	mut cname := 'multi_return'
	for i, mr_typ in mr_typs {
		mr_type_sym := t.get_type_symbol(mr_typ)
		name += mr_type_sym.name
		cname += '_$mr_type_sym.cname'
		if i < mr_typs.len - 1 {
			name += ', '
		}
	}
	name += ')'
	// existing
	existing_idx := t.type_idxs[name]
	if existing_idx > 0 {
		return existing_idx
	}
	// register
	mr_type := TypeSymbol{
		kind: .multi_return
		name: name
		cname: cname
		info: MultiReturn{
			types: mr_typs
		}
	}
	return t.register_type_symbol(mr_type)
}

pub fn (mut t Table) find_or_register_fn_type(mod string, f Fn, is_anon bool, has_decl bool) int {
	name := if f.name.len == 0 { 'fn ${t.fn_type_source_signature(f)}' } else { f.name.clone() }
	cname := if f.name.len == 0 {
		'anon_fn_${t.fn_type_signature(f)}'
	} else {
		util.no_dots(f.name.clone())
	}
	anon := f.name.len == 0 || is_anon
	existing_idx := t.type_idxs[name]
	if existing_idx > 0 && t.type_symbols[existing_idx].kind != .placeholder {
		return existing_idx
	}
	return t.register_type_symbol(
		kind: .function
		name: name
		cname: cname
		mod: mod
		info: FnType{
			is_anon: anon
			has_decl: has_decl
			func: f
		}
	)
}

pub fn (mut t Table) add_placeholder_type(name string, language Language) int {
	mut modname := ''
	if name.contains('.') {
		modname = name.all_before_last('.')
	}
	ph_type := TypeSymbol{
		kind: .placeholder
		name: name
		cname: util.no_dots(name)
		language: language
		mod: modname
	}
	// println('added placeholder: $name - $ph_type.idx')
	return t.register_type_symbol(ph_type)
}

[inline]
pub fn (t &Table) value_type(typ Type) Type {
	typ_sym := t.get_final_type_symbol(typ)
	if typ.has_flag(.variadic) {
		// ...string => string
		// return typ.clear_flag(.variadic)
		array_info := typ_sym.info as Array
		return array_info.elem_type
	}
	if typ_sym.kind == .array {
		// Check index type
		info := typ_sym.info as Array
		return info.elem_type
	}
	if typ_sym.kind == .array_fixed {
		info := typ_sym.info as ArrayFixed
		return info.elem_type
	}
	if typ_sym.kind == .map {
		info := typ_sym.info as Map
		return info.value_type
	}
	if typ_sym.kind == .string && typ.is_ptr() {
		// (&string)[i] => string
		return string_type
	}
	if typ_sym.kind in [.byteptr, .string] {
		return byte_type
	}
	if typ.is_ptr() {
		// byte* => byte
		// bytes[0] is a byte, not byte*
		return typ.deref()
	}
	// TODO: remove when map_string is removed
	if typ_sym.name == 'map_string' {
		return string_type
	}
	return void_type
}

[inline]
pub fn (t &Table) mktyp(typ Type) Type {
	match typ {
		float_literal_type { return f64_type }
		int_literal_type { return int_type }
		else { return typ }
	}
}

pub fn (mut t Table) register_fn_concrete_types(fn_name string, types []Type) bool {
	mut a := t.fn_generic_types[fn_name]
	if types in a {
		return false
	}
	a << types
	t.fn_generic_types[fn_name] = a
	return true
}

// TODO: there is a bug when casting sumtype the other way if its pointer
// so until fixed at least show v (not C) error `x(variant) =  y(SumType*)`
pub fn (t &Table) sumtype_has_variant(parent Type, variant Type) bool {
	parent_sym := t.get_type_symbol(parent)
	if parent_sym.kind == .sum_type {
		parent_info := parent_sym.info as SumType
		var_sym := t.get_type_symbol(variant)
		if var_sym.kind == .aggregate {
			var_info := var_sym.info as Aggregate
			for var_type in var_info.types {
				if !t.sumtype_has_variant(parent, var_type) {
					return false
				}
			}
			return true
		} else {
			for v in parent_info.variants {
				if v.idx() == variant.idx() {
					return true
				}
			}
		}
	}
	return false
}

// only used for debugging V compiler type bugs
pub fn (t &Table) known_type_names() []string {
	mut res := []string{cap: t.type_idxs.len}
	for _, idx in t.type_idxs {
		// Skip `int_literal_type_idx` and `float_literal_type_idx` because they shouldn't be visible to the User.
		if idx !in [0, int_literal_type_idx, float_literal_type_idx] && t.known_type_idx(idx)
			&& t.get_type_symbol(idx).kind != .function {
			res << t.type_to_str(idx)
		}
	}
	return res
}

// has_deep_child_no_ref returns true if type is struct and has any child or nested child with the type of the given name
// the given name consists of module and name (`mod.Name`)
// it doesn't care about childs that are references
pub fn (t &Table) has_deep_child_no_ref(ts &TypeSymbol, name string) bool {
	if ts.info is Struct {
		for field in ts.info.fields {
			sym := t.get_type_symbol(field.typ)
			if !field.typ.is_ptr() && (sym.name == name || t.has_deep_child_no_ref(sym, name)) {
				return true
			}
		}
	}
	return false
}

// complete_interface_check does a MxN check for all M interfaces vs all N types, to determine what types implement what interfaces.
// It short circuits most checks when an interface can not possibly be implemented by a type.
pub fn (mut t Table) complete_interface_check() {
	util.timing_start(@METHOD)
	defer {
		util.timing_measure(@METHOD)
	}
	for tk, mut tsym in t.type_symbols {
		if tsym.kind != .struct_ {
			continue
		}
		info := tsym.info as Struct
		for _, mut idecl in t.interfaces {
			if idecl.methods.len > tsym.methods.len {
				continue
			}
			if idecl.fields.len > info.fields.len {
				continue
			}
			// empty interface only generate type cast functions of the current module
			if idecl.methods.len == 0 && idecl.fields.len == 0
				&& tsym.mod != t.get_type_symbol(idecl.typ).mod {
				continue
			}
			if t.does_type_implement_interface(tk, idecl.typ) {
				$if trace_types_implementing_each_interface ? {
					eprintln('>>> tsym.mod: $tsym.mod | tsym.name: $tsym.name | tk: $tk | idecl.name: $idecl.name | idecl.typ: $idecl.typ')
				}
				t.iface_types[idecl.name] << tk
			}
		}
	}
}

// bitsize_to_type returns a type corresponding to the bit_size
// Examples:
//
// `8 > i8`
//
// `32 > int`
//
// `123 > panic()`
//
// `128 > [16]byte`
//
// `608 > [76]byte`
pub fn (mut t Table) bitsize_to_type(bit_size int) Type {
	match bit_size {
		8 {
			return i8_type
		}
		16 {
			return i16_type
		}
		32 {
			return int_type
		}
		64 {
			return i64_type
		}
		else {
			if bit_size % 8 != 0 { // there is no way to do `i2131(32)` so this should never be reached
				t.panic('compiler bug: bitsizes must be multiples of 8')
			}
			return new_type(t.find_or_register_array_fixed(byte_type, bit_size / 8, empty_expr()))
		}
	}
}

pub fn (mut t Table) does_type_implement_interface(typ Type, inter_typ Type) bool {
	if typ.idx() == inter_typ.idx() {
		// same type -> already casted to the interface
		return true
	}
	if inter_typ.idx() == error_type_idx && typ.idx() == none_type_idx {
		// `none` "implements" the Error interface
		return true
	}
	typ_sym := t.get_type_symbol(typ)
	if typ_sym.language != .v {
		return false
	}
	// generic struct don't generate cast interface fn
	if typ_sym.info is Struct {
		if typ_sym.info.is_generic {
			return false
		}
	}
	mut inter_sym := t.get_type_symbol(inter_typ)
	if typ_sym.kind == .interface_ && inter_sym.kind == .interface_ {
		return false
	}
	if mut inter_sym.info is Interface {
		// do not check the same type more than once
		for tt in inter_sym.info.types {
			if tt.idx() == typ.idx() {
				return true
			}
		}
		// verify methods
		for imethod in inter_sym.info.methods {
			if method := typ_sym.find_method(imethod.name) {
				msg := t.is_same_method(imethod, method)
				if msg.len > 0 {
					return false
				}
				continue
			}
			return false
		}
		// verify fields
		for ifield in inter_sym.info.fields {
			if ifield.typ == voidptr_type {
				// Allow `voidptr` fields in interfaces for now. (for example
				// to enable .db check in vweb)
				if t.struct_has_field(typ_sym, ifield.name) {
					continue
				} else {
					return false
				}
			}
			if field := t.find_field_with_embeds(typ_sym, ifield.name) {
				if ifield.typ != field.typ {
					return false
				} else if ifield.is_mut && !(field.is_mut || field.is_global) {
					return false
				}
				continue
			}
			return false
		}
		inter_sym.info.types << typ
		if !inter_sym.info.types.contains(voidptr_type) {
			inter_sym.info.types << voidptr_type
		}
		return true
	}
	return false
}

// resolve_generic_to_concrete resolves generics to real types T => int.
// Even map[string]map[string]T can be resolved.
// This is used for resolving the generic return type of CallExpr white `unwrap_generic` is used to resolve generic usage in FnDecl.
pub fn (mut t Table) resolve_generic_to_concrete(generic_type Type, generic_names []string, concrete_types []Type) ?Type {
	mut sym := t.get_type_symbol(generic_type)
	if sym.name in generic_names {
		index := generic_names.index(sym.name)
		if index >= concrete_types.len {
			return none
		}
		typ := concrete_types[index]
		if typ == 0 {
			return none
		}
		return typ.derive_add_muls(generic_type).clear_flag(.generic)
	}
	match mut sym.info {
		Array {
			mut elem_type := sym.info.elem_type
			mut elem_sym := t.get_type_symbol(elem_type)
			mut dims := 1
			for mut elem_sym.info is Array {
				info := elem_sym.info as Array
				elem_type = info.elem_type
				elem_sym = t.get_type_symbol(elem_type)
				dims++
			}
			if typ := t.resolve_generic_to_concrete(elem_type, generic_names, concrete_types) {
				idx := t.find_or_register_array_with_dims(typ, dims)
				return new_type(idx).derive_add_muls(generic_type).clear_flag(.generic)
			}
		}
		ArrayFixed {
			if typ := t.resolve_generic_to_concrete(sym.info.elem_type, generic_names,
				concrete_types)
			{
				idx := t.find_or_register_array_fixed(typ, sym.info.size, None{})
				return new_type(idx).derive_add_muls(generic_type).clear_flag(.generic)
			}
		}
		Chan {
			if typ := t.resolve_generic_to_concrete(sym.info.elem_type, generic_names,
				concrete_types)
			{
				idx := t.find_or_register_chan(typ, typ.nr_muls() > 0)
				return new_type(idx).derive_add_muls(generic_type).clear_flag(.generic)
			}
		}
		FnType {
			mut func := sym.info.func
			if func.return_type.has_flag(.generic) {
				if typ := t.resolve_generic_to_concrete(func.return_type, generic_names,
					concrete_types)
				{
					func.return_type = typ
				}
			}
			func.params = func.params.clone()
			for mut param in func.params {
				if param.typ.has_flag(.generic) {
					if typ := t.resolve_generic_to_concrete(param.typ, generic_names,
						concrete_types)
					{
						param.typ = typ
					}
				}
			}
			idx := t.find_or_register_fn_type('', func, true, false)
			return new_type(idx).derive_add_muls(generic_type).clear_flag(.generic)
		}
		MultiReturn {
			mut types := []Type{}
			mut type_changed := false
			for ret_type in sym.info.types {
				if typ := t.resolve_generic_to_concrete(ret_type, generic_names, concrete_types) {
					types << typ
					type_changed = true
				} else {
					types << ret_type
				}
			}
			if type_changed {
				idx := t.find_or_register_multi_return(types)
				return new_type(idx).derive_add_muls(generic_type).clear_flag(.generic)
			}
		}
		Map {
			mut type_changed := false
			mut unwrapped_key_type := sym.info.key_type
			mut unwrapped_value_type := sym.info.value_type
			if typ := t.resolve_generic_to_concrete(sym.info.key_type, generic_names,
				concrete_types)
			{
				unwrapped_key_type = typ
				type_changed = true
			}
			if typ := t.resolve_generic_to_concrete(sym.info.value_type, generic_names,
				concrete_types)
			{
				unwrapped_value_type = typ
				type_changed = true
			}
			if type_changed {
				idx := t.find_or_register_map(unwrapped_key_type, unwrapped_value_type)
				return new_type(idx).derive_add_muls(generic_type).clear_flag(.generic)
			}
		}
		Struct, Interface, SumType {
			if sym.info.is_generic {
				mut nrt := '$sym.name<'
				for i in 0 .. sym.info.generic_types.len {
					if ct := t.resolve_generic_to_concrete(sym.info.generic_types[i],
						generic_names, concrete_types)
					{
						gts := t.get_type_symbol(ct)
						nrt += gts.name
						if i != sym.info.generic_types.len - 1 {
							nrt += ', '
						}
					}
				}
				nrt += '>'
				mut idx := t.type_idxs[nrt]
				if idx == 0 {
					idx = t.add_placeholder_type(nrt, .v)
				}
				return new_type(idx).derive_add_muls(generic_type).clear_flag(.generic)
			}
		}
		else {}
	}
	return none
}
