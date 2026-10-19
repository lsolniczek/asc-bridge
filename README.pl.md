# ASC Bridge

[English](README.md) · [Współtworzenie](CONTRIBUTING.md) · [Licencja MIT](LICENSE)

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

Interfejs aplikacji jest obecnie po polsku; opisy narzędzi MCP są po angielsku.

Aplikacja musi działać podczas korzystania z MCP. Zamknięcie okna pozostawia
ją uruchomioną; **⌘Q** zatrzymuje serwer. Pierwsza wersja obsługuje jeden klucz zespołu.

## Narzędzia

| Narzędzie | Działanie |
| --- | --- |
| `asc_list_apps` | Lista aplikacji i ich identyfikatorów |
| `asc_get_app` | Szczegóły aplikacji |
| `asc_list_versions` | Wersje aplikacji i ich stan |
| `asc_get_version` | Szczegóły i stan konkretnej wersji |
| `asc_list_localizations` | Lokalizacje wersji i zapisane teksty |
| `asc_create_version` | Utworzenie wersji, domyślnie z ręcznym wydaniem |
| `asc_create_localization` | Dodanie lokalizacji wersji |
| `asc_update_localization` | Opis, „Co nowego”, tekst promocyjny, keywords, marketing URL i support URL |
| `asc_list_app_infos` | App Info aplikacji, w tym stan i identyfikatory |
| `asc_list_app_info_localizations` | Nazwa, podtytuł i polityka prywatności w poszczególnych językach |
| `asc_create_app_info_localization` | Dodanie języka App Info z nazwą i opcjonalnymi metadanymi |
| `asc_update_app_info_localization` | Zmiana nazwy, podtytułu i metadanych prywatności |
| `asc_list_builds` | Buildy aplikacji, filtry platformy, numeru, wersji marketingowej i stanu przetwarzania |
| `asc_get_build` | Szczegóły buildu i stan przetwarzania |
| `asc_get_version_build` | Build przypięty do wersji App Store |
| `asc_set_version_build` | Przypięcie istniejącego buildu do wersji |
| `asc_list_beta_groups` | Podstawowe informacje o grupach TestFlight |
| `asc_list_beta_build_localizations` | Teksty „What to Test” buildu w TestFlight |
| `asc_create_beta_build_localization` | Dodanie języka i tekstu „What to Test” |
| `asc_update_beta_build_localization` | Zmiana tekstu „What to Test” |
| `asc_list_customer_reviews` | Opinie użytkowników, filtrowanie oceną i terytorium |
| `asc_get_customer_review_response` | Odczyt odpowiedzi dewelopera na opinię |
| `asc_upsert_customer_review_response` | Utworzenie lub zastąpienie publicznej odpowiedzi na opinię |

Łącznie 23 narzędzia. Mapowanie na endpointy, argumenty i listę dalszych możliwości
API opisuje [docs/endpoints.md](docs/endpoints.md).

Przykładowe polecenie dla agenta:

> Znajdź moją aplikację, utwórz wersję iOS 1.2.0 i ustaw polski opis oraz
> „Co nowego”. Najpierw odczytaj istniejące wersje i lokalizacje.

> Odczytaj App Info i polskie lokalizacje. Ustaw nazwę, podtytuł i keywords,
> zachowując pozostałe teksty. Jeśli brakuje języka, dodaj go w App Info i wersji.

> Pokaż najnowsze poprawnie przetworzone buildy iOS. Przypnij wskazany build do
> wersji 1.2.0 i uzupełnij angielski tekst „What to Test” w TestFlight.

> Pokaż najnowsze jednogwiazdkowe opinie z Polski i odczytaj dotychczasowe odpowiedzi.

Zmiany wykonują się od razu, bez potwierdzania w aplikacji. Narzędzia nie wysyłają
wersji do recenzji i nie publikują aplikacji. Nadal obowiązują uprawnienia klucza
i reguły Apple: opis i „Co nowego” wymagają edytowalnego stanu wersji, a tekst
promocyjny można zmieniać niezależnie. Dodając nowy język, utwórz zgodne lokalizacje
App Info i wersji; są to osobne wywołania. Przypięcie buildu nie wysyła wersji do
recenzji. Narzędzie odpowiedzi na opinię od razu zapisuje publiczny tekst i zastępuje
istniejącą odpowiedź; jego publikacja w App Store może się opóźnić.

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

Kod projektu, własna ikona i dokumentacja są udostępnione na [licencji MIT](LICENSE).
Licencje zależności są zebrane w [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
i dołączane do pakietu aplikacji. Instrukcja przygotowania repozytorium GitHub
znajduje się w [docs/publishing.md](docs/publishing.md).
