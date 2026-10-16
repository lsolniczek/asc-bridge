# ASC Bridge

Mała lokalna aplikacja macOS, która udostępnia App Store Connect przez MCP.
Importujesz klucz zespołu `.p8` w aplikacji. Codex lub inny klient MCP korzysta
z narzędzi, a aplikacja podpisuje JWT i wysyła żądania do Apple. Agent nie
otrzymuje klucza Apple ani podpisanego JWT.

## Uruchomienie

Wymagania: macOS 14+, do budowania Xcode 26.4 / Swift 6.3 i Python 3 do testu HTTP.

```sh
./scripts/build-app.sh
open "dist/ASC Bridge.app"
```

1. W App Store Connect znajdź **Key ID** oraz **Issuer ID** klucza zespołu.
2. W aplikacji wpisz oba identyfikatory, wybierz `.p8` i kliknij **Zapisz w Keychain**.
3. Kliknij **Testuj zapisany klucz**.
4. Kliknij **Skopiuj konfigurację Codexa** i dodaj ją do `~/.codex/config.toml`.
   Odśwież serwery MCP w kliencie lub uruchom go ponownie.

W innych klientach wybierz Streamable HTTP, adres `http://127.0.0.1:43129/mcp`
i nagłówek `Authorization` z kopiowanej konfiguracji. To osobny token dostępu
do lokalnej aplikacji, a nie klucz Apple. Nie dodawaj klucza `.p8` do konfiguracji,
repozytorium ani rozmowy z agentem.

Aplikacja musi działać podczas korzystania z MCP. Zamknięcie okna pozostawia
ją uruchomioną; **⌘Q** zatrzymuje serwer. Pierwsza wersja obsługuje jeden klucz zespołu.

## Narzędzia

| Narzędzie | Działanie |
| --- | --- |
| `asc_list_apps` | Lista aplikacji i ich identyfikatorów |
| `asc_list_versions` | Wersje aplikacji i ich stan |
| `asc_list_localizations` | Lokalizacje wersji i zapisane teksty |
| `asc_create_version` | Utworzenie wersji, domyślnie z ręcznym wydaniem |
| `asc_create_localization` | Dodanie lokalizacji wersji |
| `asc_update_localization` | Zmiana `description`, `whatsNew`, `promotionalText` |

Przykładowe polecenie dla agenta:

> Znajdź moją aplikację, utwórz wersję iOS 1.2.0 i ustaw polski opis oraz
> „Co nowego”. Najpierw odczytaj istniejące wersje i lokalizacje.

Zmiany wykonują się od razu, bez potwierdzania w aplikacji. Narzędzia nie wysyłają
wersji do recenzji i nie publikują aplikacji. Nadal obowiązują uprawnienia klucza
i reguły Apple: opis i „Co nowego” wymagają edytowalnego stanu wersji, a tekst
promocyjny można zmieniać niezależnie. Dodanie nowego języka wymaga też odpowiedniej
lokalizacji App Info w ASC; ten MVP edytuje wyłącznie lokalizacje wersji.

## Historia

Zakładka **Historia MCP** pokazuje metodę, narzędzie, parametry, czas, wynik i błędy.
Zapis obejmuje również inicjalizację, listowanie narzędzi, powiadomienia oraz
odrzucone próby. Historia przetrwa restart aplikacji:

```text
~/Library/Application Support/ASCBridge/history.jsonl
```

Interfejs pokazuje ostatnie 500 wywołań; pełny plik pozostaje na dysku. Teksty
metadanych są częścią historii. Klucze, nagłówki autoryzacji i JWT są usuwane
z zapisu. Gdy nie można zapisać początku wywołania, aplikacja go nie wykonuje.
Wpis bez zakończenia oznacza trwającą lub przerwaną operację — przed powtórzeniem
zmiany sprawdź stan w Apple. Plik historii i odpowiedź Apple nie tworzą wspólnej
transakcji; mutacje nie są automatycznie ponawiane.

## Klucze i podpis aplikacji

Keychain ogranicza dostęp do aplikacji, która zapisała klucz. Domyślny lokalny build
ma podpis ad-hoc. Po przebudowaniu macOS może ponownie zapytać o dostęp do Keychain.
Dla stabilnej tożsamości aplikacji można użyć własnego certyfikatu:

```sh
ASC_BRIDGE_SIGN_IDENTITY="Developer ID Application: Twoja nazwa (TEAMID)" ./scripts/build-app.sh
```

To systemowa kontrola dostępu do klucza; aplikacja nie pyta o zatwierdzenie każdej
zmiany w ASC. Oryginalny `.p8` pozostaje w wybranym przez Ciebie miejscu. Nie zostawiaj
go w katalogu dostępnym agentowi, jeśli ma korzystać wyłącznie z brokera. Granicę
dostępu opisuje [docs/security.md](docs/security.md).

## Rozwój i sprawdzanie

```sh
./scripts/check.sh
./scripts/build-app.sh --debug
```

Testy używają wygenerowanych kluczy i atrap HTTP. Test transportu uruchamia aplikację
w jawnym trybie `--smoke-server` z atrapą ASC, osobnym portem 43130 i tymczasową
historią. Nie odczytuje prawdziwego Keychain i nie łączy się z Apple.

[AGENTS.md](AGENTS.md) jest mapą projektu; [ARCHITECTURE.md](ARCHITECTURE.md)
opisuje granice modułów. Wymagania, decyzje i źródła są w [docs](docs/product.md),
zgodnie z ideą krótkich instrukcji i wiedzy wersjonowanej razem z kodem.
