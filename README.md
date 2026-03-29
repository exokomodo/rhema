# Rhema

**LLMs living in a persistent Common Lisp REPL.**

Rhema (Greek ῥῆμα — the spoken, performative word) is a system that embeds
large language models inside a persistent Common Lisp REPL. The model doesn't
generate Lisp on demand and discard it — it *lives* in the REPL. It defines its
own tools, evolves them across sessions, and uses the REPL as external memory
and computation.

## Why Common Lisp?

- **Homoiconicity** — code is data. The gap between what a model thinks and
  what it writes is minimal.
- **Uniform s-expression syntax** — a trivial grammar means fewer generation
  errors and simpler parsing.
- **Token efficiency** — more semantic content per token than most languages.
- **Frozen spec** — Common Lisp was standardized in 1994 and hasn't changed.
  Every model's training data is consistent.

## Background

The conceptual framework comes from de la Torre (2025):

> **"From Tool Calling to Symbolic Thinking: LLMs in a Persistent Lisp
> Metaprogramming Loop"**
> — arXiv [2506.10021v1](https://arxiv.org/abs/2506.10021v1)

The paper proposes embedding LLMs in a persistent Lisp metaprogramming
environment but provides no implementation. Rhema is that implementation.

### The Church/Turing angle

Alonzo Church (a Presbyterian) gave us lambda calculus — the foundation of
functional programming. Turing gave us mutable state — the foundation of
imperative programming. One might argue that functional languages are,
therefore, the Lord's language. We leave the theological implications as an
exercise for the reader.

## Status

Early development. Repo bootstrap in progress.

## License

[CC0 1.0 Universal](LICENSE)

## Contributors

- [James](https://github.com/jamesaorson)
- [diatrix (Nathan)](https://github.com/diatrix)
- [SonicCyclops](https://github.com/soniccyclops)
- [ExoKomodo](https://github.com/exokomodo-bot)
