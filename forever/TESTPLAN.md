# Testplan i spelet

Det här kan bara du göra, eftersom det kräver spelet. Det tar ungefär 15 minuter. Bocka av varje rad. Om något inte stämmer, skriv `/fg report`, kopiera texten och skicka den till mig. Inget skickas automatiskt.

## 1. Installera

1. Packa upp `ForeverGuide-0.7.0.zip` i `World of Warcraft/_forever_/Interface/AddOns/`.
2. Starta spelet och logga in.
3. **Väntat:** i chatten står "Forever Guide v0.7.0 loaded".

## 2. Självtest (viktigast)

| Gör | Väntat |
|---|---|
| `/fg selftest` | "Everything Forever Guide needs is here." |
| Läs raden "not available" | Visar högst `PlaySoundFile`, `StopSound` och `GetSpellBaseCooldown`. Där används en reservlösning. |

Om något står som **missing** behöver jag rapporten.

## 3. Funktion för funktion

| # | Gör | Väntat |
|---|---|---|
| 1 | Prata med en NPC som har en quest | Texten läses upp med datorns röst |
| 2 | `/fg voices` | Listar datorns röster |
| 3 | `/fg sim` | Fönster med stats och formler, utan fel |
| 4 | Tryck på väsktangenten (B) | Forever Bags öppnas i stället för spelets väskor |
| 5 | Högerklicka på en dryck i Forever Bags | Du dricker, och inget fel om "action blocked" visas |
| 6 | Skriv `ah` i väskans sökruta | Bara föremål som är värda mer på AH är tydliga |
| 7 | Öppna banken, sedan `/fg bank` | Din karaktär visas med guld och bank |
| 8 | Besök en handlare | Panelen "sell N items" syns bredvid handlaren |
| 9 | Öppna auktionshuset | Panelen Forever Market syns till höger |
| 10 | Fliken **Scan** och sedan **Quick scan** | "Quick scan done: N items priced" |
| 11 | Fliken **Sell** | Ett föremål med pris och skäl visas. Lägg upp ett billigt föremål som prov. |
| 12 | Fliken **Cancel** | Visar hur många av dina auktioner som är underbjudna |
| 13 | Besök din klasstränare, sedan `/fg route` | Under "Class trainer" står vad nästa besök kostar |
| 14 | `/fg talents` | Föreslår nästa talang, eller säger att mallen saknas |
| 15 | `/fg talents export` | En text som börjar med `FGT1`. Klistra in den på webbsidans flik Talanger. |
| 16 | `/fg atlas scan` | Listar zoner som spelet känner till men som Forever Guide saknar |
| 17 | `/fg atlas export` | Spara texten i `atlas.txt` och kör `python companion/atlas_import.py --file atlas.txt` |
| 18 | `/fg options`, byt till Stormwind | Alla fönster byter tema |

## 4. Om något går fel

1. Skriv `/fg report`.
2. Kopiera texten med Ctrl+A och Ctrl+C.
3. Klistra in den här i chatten.

Rapporten innehåller version, självtestet och de senaste felen. Den innehåller inga personuppgifter utöver ditt karaktärsnamn, om det står i ett felmeddelande.
