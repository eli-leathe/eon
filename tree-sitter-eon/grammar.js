/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  OR: 1,
  AND: 2,
  EQUALITY: 3,
  SUM: 4,
  PRODUCT: 5,
  UNARY: 6,
  APPLICATION: 7,
  FIELD: 8,
};

module.exports = grammar({
  name: 'eon',

  extras: $ => [
    /[ \t\f]/,
    $.comment,
  ],

  word: $ => $.identifier,

  rules: {
    source_file: $ => declarationContainer($),

    declaration: $ => seq(
      field('name', $.identifier),
      '=',
      field('value', choice($.map, $._expression)),
    ),

    map: $ => seq(
      '{',
      declarationContainer($),
      '}',
    ),

    _expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.application_expression,
      $._postfix_expression,
    ),

    binary_expression: $ => choice(
      binary($, 'or', PREC.OR),
      binary($, 'and', PREC.AND),
      binary($, '==', PREC.EQUALITY),
      binary($, '+', PREC.SUM),
      binary($, '-', PREC.SUM),
      binary($, '*', PREC.PRODUCT),
      binary($, '/', PREC.PRODUCT),
    ),

    unary_expression: $ => prec(PREC.UNARY, seq(
      field('operator', '-'),
      field('operand', choice($.unary_expression, $._postfix_expression)),
    )),

    application_expression: $ => prec.left(PREC.APPLICATION, seq(
      field('function', $._postfix_expression),
      repeat1(field('argument', $._postfix_expression)),
    )),

    _postfix_expression: $ => choice(
      $.field_expression,
      $._primary_expression,
    ),

    field_expression: $ => prec.left(PREC.FIELD, seq(
      field('value', $._postfix_expression),
      '.',
      field('field', $.identifier),
    )),

    _primary_expression: $ => choice(
      $.identifier,
      $.boolean,
      $.number,
      $.string,
      $.character,
      $.parenthesized_expression,
    ),

    parenthesized_expression: $ => seq('(', $._expression, ')'),

    identifier: _ => token(choice(
      /[A-Za-z_][A-Za-z0-9_]*/,
      /@"(?:\\[^\r\n\x00-\x1f\x7f]|[^"\\\r\n\x00-\x1f\x7f])+"/,
    )),

    boolean: _ => choice('true', 'false'),

    number: _ => token(choice(
      /0[xX][0-9A-Fa-f_]+(?:\.[0-9A-Fa-f_]+)?(?:[pP][+-]?[0-9A-Za-z_]+)?/,
      /0[bB][01_]+/,
      /0[oO][0-7_]+/,
      /[0-9][0-9A-Za-z_]*(?:\.[0-9A-Za-z_]+)?(?:[eEpP][+-]?[0-9A-Za-z_]+)?/,
    )),

    string: _ => token(/"(?:\\[^\r\n\x00-\x1f\x7f]|[^"\\\r\n\x00-\x1f\x7f])*"/),
    character: _ => token(/'(?:\\[^\r\n\x00-\x1f\x7f]|[^'\\\r\n\x00-\x1f\x7f])*'/),
    comment: _ => token(seq('//', /[^\r\n]*/)),

    _separator: _ => choice(';', /\r?\n/),
  },
});

function declarationContainer($) {
  return choice(
    repeat($._separator),
    seq(
      repeat($._separator),
      $.declaration,
      repeat(seq(repeat1($._separator), $.declaration)),
      repeat($._separator),
    ),
  );
}

function binary($, operator, precedence) {
  return prec.left(precedence, seq(
    field('left', $._expression),
    field('operator', operator),
    field('right', $._expression),
  ));
}
