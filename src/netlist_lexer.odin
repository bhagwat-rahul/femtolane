package femtolane

// The lexer returns tokens [0-255] if it is an unknown character, otherwise one
// of these for known things.
// TODO(rahul): Maybe we need to concretely support wires, assigns, etc. with their attributes here?
Token :: enum {
	tok_eof        = -1,
	tok_newline    = -2,
	// commands
	tok_def        = -3,
	tok_extern     = -4,
	// primary
	tok_identifier = -5,
	tok_number     = -6,
}

// TODO(rahul):fix
EOF :: -1 // End of file byte

getTokens :: proc() {
	charParsed: rune
	for charParsed == EOF {
	}
}
