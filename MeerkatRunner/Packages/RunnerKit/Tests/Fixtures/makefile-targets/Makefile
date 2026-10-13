PORT := 8080

.PHONY: build dev serve

build:
	npm run build

dev: build
	npm run dev -- --port $(PORT)

serve:
	python3 -m http.server 8080
