# Forever Guide

En följeslagare till **World of Warcraft: Forever**. Den består av tre delar:

| Del | Var | Vad den gör |
|---|---|---|
| Webbsida | `index.html`, `app.js` | Väljer klass och ras, simulerar karaktären och jämför raser med samma utrustning. |
| Addon | `addon/ForeverGuide`, `addon/ForeverGuide_Voices` | Läser upp quest-texter, NPC-dialog och böcker. Läser av stats och formler och räknar ut skada. |
| Röstverktyg | `companion/` | Skapar AI-röster med öppen källkod av texterna som addonen har sparat. Hämtar data från Battle.net API. |

## Varför tre delar?

- **Klass och ras väljs på webben.** Addons laddas inte på skärmen där du skapar en karaktär.
- **AI-rösterna skapas utanför spelet.** Addons kan inte köra AI-modeller eller prata med andra program. Addonen sparar därför texterna när du loggar ut. Verktyget gör ljudfiler av dem, och spelet spelar upp dem efter en omstart.
- **API-nyckeln hålls lokalt.** Allt på GitHub Pages är offentligt. Därför används Battle.net-nyckeln bara av ett skript på din dator.

## Addonen

Kopiera båda mapparna i `addon/` till spelets `Interface/AddOns`.

| Kommando | Funktion |
|---|---|
| `/fg read` | Läser upp den valda questen i questloggen. |
| `/fg stop` | Avbryter uppläsningen. |
| `/fg auto on\|off` | Läser upp automatiskt när en NPC visar en quest. |
| `/fg mode voices\|builtin\|both` | Väljer AI-klipp, spelets röst eller båda (standard). |
| `/fg voices`, `/fg voice male 2` | Listar och väljer spelets inbyggda röster. |
| `/fg sim` | Visar stats, formler sorterade efter skada per sekund och vad som höjer skadan mest. |
| `/fg export` | Ger en text som du klistrar in i webbsimulatorn. |
| `/fg target 3` | Räknar mot en fiende tre nivåer över dig (en boss). |

Quest-fönstret får också knappen **Read aloud**.

### Tekniska val

- Forever använder det moderna addon-API:et (interface `16001`). Därför finns stöd för både `C_SpellBook`/`C_Spell` och de äldre funktionerna.
- I strid döljer spelet många värden för addons ("secret values"). Simulatorn tar därför bara ögonblicksbilder utanför strid.
- `C_VoiceChat.SpeakText` bytte parametrar i patch 12.0. Addonen använder den nya ordningen. Om rösten låter fel, skriv `/fg legacy on`.

## Röstverktyget

```bash
cd companion
pip install numpy soundfile kokoro          # eller chatterbox-tts
python forever_voice.py --wow "C:/Program Files (x86)/World of Warcraft/_forever_" --dry-run
python forever_voice.py --wow "C:/Program Files (x86)/World of Warcraft/_forever_" --engine kokoro
```

| Motor | Modell | Licens | När den passar |
|---|---|---|---|
| `kokoro` | Kokoro-82M | Apache-2.0 | Börja här. Snabb och fungerar utan grafikkort. |
| `chatterbox` | Chatterbox | MIT | Egna karaktärsröster genom kloning från ett kort ljudklipp. |
| `http` | Fish Audio Drama 3, Kokoro-FastAPI med flera | Beror på modellen | Stora modeller på en egen eller hyrd server med ett OpenAI-liknande `/audio/speech`. |
| `test` | – | – | Testar hela kedjan utan modell. |

**Fish Audio Drama 3** har öppna vikter under Fish Audio Community License. Privat användning är gratis. Modellen är stor (35B MoE) och behöver cirka 32–48 GB grafikminne. Kör den därför på en hyrd GPU och skapa röster för en hel zon i taget:

```bash
python forever_voice.py --wow "..." --engine http --url http://din-gpu-server:8080/v1 --model drama-3 --voices voices.example.json
```

I `voices.example.json` finns regianvisningar per texttyp, till exempel `[warm, friendly]` för NPC-dialog. Där väljer du också röst per NPC.

Samma NPC får alltid samma röst. Verktyget läser bara addonens sparfil och skriver ljudfiler. Det rör aldrig spelet medan det körs.

## Battle.net API

```bash
export BLIZZARD_CLIENT_ID=...
export BLIZZARD_CLIENT_SECRET=...
python blizzard_fetch.py races
python blizzard_fetch.py character --realm din-realm --name Oskar
```

Skriptet använder namespace för Classic Era (`classic1x`). Blizzard har inte sagt vilken namespace Forever får. Ändra `--flavor` när den är känd.

## Tester

```bash
pip install lupa numpy soundfile requests
python -m unittest discover tests      # addonens logik i Lua 5.1 och röstverktyget
node --test tests/app.test.js          # webbsidans beräkningar
```

## Begränsningar

- Simulatorn räknar med reglerna från 2004 och omvandlingstal för nivå 60. Den ger uppskattningar, inte en fullständig stridslogg.
- Formlernas skada läses från tooltip-texten. Om Forever skriver tooltips på ett annat sätt kan vissa formler saknas.
- Klasser, raser och racials följer 2004. Kontrollera dem om Blizzard ändrar något i Forever.
- Nya ljudfiler syns först när spelet har startats om.
