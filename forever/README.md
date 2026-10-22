# Forever Guide

En följeslagare till **World of Warcraft: Forever**. Den består av fyra delar:

| Del | Var | Vad den gör |
|---|---|---|
| Webbsida | `index.html`, `app.js` | Väljer klass och ras, simulerar karaktären, ger säljråd för AH och visar historik över datauppdateringar. Har två teman och egna färger. |
| Addon | `addon/ForeverGuide` | Läser upp quest-texter med en egen röst per NPC, simulerar skada och ger råd för auktionshuset. Har två teman och egna färger. |
| Röstverktyg | `companion/forever_voice.py`, `quest_db.py` | Skapar AI-röster med öppen källkod, även zonpaket i förväg. |
| Underhåll | `companion/patch_watch.py`, `build_data.py` | En lokal språkmodell läser patchnoter och uppdaterar speldatan. |

All speldata (racials, stridsregler, AH-avgifter) ligger i `data/gamedata.json`. Både webben och addonen läser den, så en hotfix kräver ingen kodändring.

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
| `/fg options` | Tema (Orgrimmar eller Stormwind), egna färger och inställningar. |
| `/fg ah` | Säljråd för dina väskor, fynd och dina försäljningar. |
| `/fg variety on\|off` | En egen inbyggd röst och ett eget tempo per NPC. |

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

## Auktionshuset

Forever har inget öppet API för auktionshuset. Addonen samlar därför priser på två sätt: med en fullskanning (högst en gång per 15 minuter) och från varje sökning du gör. Om servern stryper en skanning kommer den tillbaka tom. Då behåller addonen de gamla priserna.

| Funktion | Hur |
|---|---|
| Marknadspris | Viktat snitt av de billigaste 30 % av utbudet, utan uppenbart överprissatta auktioner |
| Historiskt pris | Glidande medelvärde över dina skanningar |
| Säljchans | Auktioner som försvinner mellan två skanningar trots att de hade tid kvar räknas som sålda |
| Handlare eller AH | Räknar med avgift, deposition och upp till tre försök. Säljs det inte, går det till handlaren. |
| Fynd | Auktioner under handlarens pris |
| Försäljningar | Läses från AH-posten och ger summa och bästa tid att lägga upp |
| Säljknapp | Hos handlare: säljer grått och, om du vill, handelsvaror som är värda mer där |

`python forever_ah.py --wow "..." --out prices.json` gör en fil som du öppnar på webbsidans flik Auktionshus.

## Patchnoter med lokal språkmodell

```bash
ollama pull qwen3:14b
python patch_watch.py --file hotfix.txt                 # visar förslag och skriver en rapport
python patch_watch.py --fetch --apply --commit          # källor i patch_sources.json
```

Modellen får bara ändra `data/gamedata.json`. Varje ändring måste citera en mening som finns i patchnoterna, matcha det nuvarande värdet och hålla sig inom rimliga gränser. Därefter körs testerna, och vid fel rullas allt tillbaka. Kodförslag hamnar i `reports/`, så att du kan granska dem.

## Zonpaket

```bash
python quest_db.py --sql classicdb.sql --out quests.json
python forever_voice.py --wow "..." --quests quests.json --zone 12 --max-level 10
```

Addonen nycklar quest-texter på quest-ID och sparar ditt namn som `$N`. Därför passar ett zonpaket alla dina karaktärer. Quest-texterna tillhör Blizzard, så dela inte de skapade ljudfilerna.

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
python -m unittest discover tests      # addonens logik i Lua 5.1 och alla verktyg
node --test tests/app.test.js          # webbsidans beräkningar
```

## Begränsningar

- Simulatorn räknar med reglerna från 2004 och omvandlingstal för nivå 60. Den ger uppskattningar, inte en fullständig stridslogg.
- Formlernas skada läses från tooltip-texten. Om Forever skriver tooltips på ett annat sätt kan vissa formler saknas.
- Klasser, raser och racials följer 2004. Kontrollera dem om Blizzard ändrar något i Forever.
- Nya ljudfiler syns först när spelet har startats om.
- AH-avgifterna för neutrala auktionshus är osäkra. De ligger i `data/gamedata.json` och kan rättas där.
- Det är oklart om Forever använder det moderna eller det klassiska auktions-API:et. Addonen stöder båda.
