# Makefile — KV32 Docs: AsciiDoc → PDF
#
# Targets:
#   make [all]    — build all PDFs
#   make setup    — install asciidoctor + asciidoctor-pdf (requires gem)
#   make clean    — remove generated PDFs
#
# Usage:
#   make                         # build everything
#   make kv32_soc_datasheet.pdf  # build one file
#   make setup                   # install tools (once)

ASCIIDOCTOR_PDF ?= asciidoctor-pdf

# Common flags for all documents
ADOC_FLAGS := -a toc \
              -a toclevels=3 \
              -a sectnums \
              -a icons=font \
              -a source-highlighter=rouge \
              -a pdf-fontsdir=GEM_FONTS_DIR

SRCS := $(wildcard *.adoc)
PDFS := $(SRCS:.adoc=.pdf)

.PHONY: all setup clean

all: $(PDFS)

%.pdf: %.adoc
	$(ASCIIDOCTOR_PDF) $(ADOC_FLAGS) -o $@ $<
	@$(RM) -rf images .asciidoctor package-lock.json  package.json

cache_benchmark_report.pdf: cache_benchmark_report.adoc
	$(ASCIIDOCTOR_PDF) $(ADOC_FLAGS) -r asciidoctor-diagram -o $@ $<
	@$(RM) -rf images .asciidoctor package-lock.json  package.json

# ── Setup ─────────────────────────────────────────────────────────────────────

.PHONY: setup
setup:
	@echo "=== Installing asciidoctor and asciidoctor-pdf ==="
	gem install --user-install asciidoctor
	gem install --user-install asciidoctor-pdf
	gem install --user-install asciidoctor-diagram
	gem install --user-install rouge
	@echo "=== Done. Run 'asciidoctor-pdf --version' to verify ==="

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -f $(PDFS)
