APP     := Colok.app
BUILD   := .build/release
DEST    := $(APP)/Contents

.PHONY: all build bundle install clean run doctor

all: bundle

build:
	swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(DEST)/MacOS $(DEST)/Resources
	cp Resources/Info.plist $(DEST)/Info.plist
	cp $(BUILD)/ColokBar $(DEST)/MacOS/ColokBar
	cp $(BUILD)/colok $(DEST)/MacOS/colok
	codesign --force --deep --sign - $(APP) 2>/dev/null || true
	@echo "built $(APP) - open it, or: make install"

install: bundle
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	mkdir -p $(HOME)/.local/bin
	ln -sf /Applications/$(APP)/Contents/MacOS/colok $(HOME)/.local/bin/colok
	@echo "installed. add ~/.local/bin to PATH for the 'colok' CLI"

run: bundle
	open $(APP)

doctor: build
	$(BUILD)/colok doctor

clean:
	rm -rf .build $(APP)
