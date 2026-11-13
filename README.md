# On-Call Board

An installable web app for anaesthesia on-call teams. It assigns OT cases, APS reviews, emergency calls, preop assessments and list preparation to second and first on-call doctors, shows the shift as a timeline, and produces handover text to paste into the team chat.

## Deploy on Vercel
1. Go to https://vercel.com/new and import this GitHub repository.
2. Leave the settings as they are (`vercel.json` already sets the build and output folder) and press **Deploy**.
3. Every push to `master` redeploys automatically.

On Vercel's free Hobby plan, Git deployments only run for commits authored by the account owner, so commits here are authored as the repo owner.

## Install on a phone
Open the Vercel link, then:
- **iPhone (Safari):** Share → *Add to Home Screen*.
- **Android (Chrome):** menu → *Install app*.
It then opens full screen and works without signal.

## Develop
- Edit `src/app.html`, then run `./build.sh` to rebuild `public/index.html`.
- `public/` holds the manifest, service worker (offline support) and icons.

## Rota and teams
One board holds the whole department. Under **Rota & teams**:
- **All staff:** everyone, once, with their grade (3rd, 2nd, 1st on-call) and whether they usually cover Obs & Gyne.
- **Teams:** the usual group for a night, with coordinator, list prep and Obs & Gyne marked.
- **Rota:** which team is on each date. *Fill rota* rotates the teams in order for 1–8 weeks.
- **Shift times:** weekday morning duties 07:30–14:00, weekday night 18:00–07:30, holiday 08:00–08:00. Weekend days (Fri/Sat by default) and public holiday dates use the holiday shift.
- **First on-call duties** (held for the whole 24 h on-call, each with its duty phone): APS, Trauma & Code blue · Assessment · Emergency call · OB/GYN. Set in the team, changeable on the day. Work of that kind goes to the duty holder first; in the morning session first on-calls do only their outside duty.
- **Third on-call** roles: Cardiac anaesthesia, Regular OT. **Trainee on-call** can be added to a team.

The app always opens on the shift running now (at 03:00 that is the shift that started at 18:00 the evening before). Use ‹ › to look at other nights.

**Import rota from text** (second on-calls): one block per day — a date line, then `Team:`, `Trainee:`, `List prep:`, `APS:`, `Assessment:`, `Emergency:`, `OBGYN:`, `Second:`, `Coordinator:`, `Cardiac:`, `Regular OT:` with names separated by commas. It sets who is on that day's morning and night shifts, adds new names to All staff, keeps existing work and logs the import.

**Swaps:** on the Board a second on-call taps *Swap* on a doctor and picks who covers. Their tasks and roles move across, and every change is logged on that shift.
**Handover:** the next shift shows a banner to carry over anything unfinished from the previous one.

## Coverage plan (night and holiday on-call)
The **Coverage** tab splits the shift into equal blocks:
- **2nd on-call · OT:** second on-calls take equal turns in OT (the coordinator joins the turns only when there is a single other second on-call).
- **1st on-call · phone & OT:** first on-calls take equal turns holding the phone (emergency calls, assessments, APS, code blue) and covering OT; the others are free.
- **OB/GYN:** one first on-call covers it alone for the whole shift.

A second on-call makes the plan in one tap and can change any block. Auto-assign follows it, the Board shows who covers right now, *My work* shows each doctor's turns, and the plan can be copied to the group chat.

## Roles
Each phone chooses **who you are** (button at the top). The app then adapts:
- **Third on-call:** read-only overview of the whole shift, including help requests.
- **Second on-call:** assigns any task to a doctor from the task card, and posts each first on-call *Inside OT* (any or a named theatre) or *Outside OT*.
- **First on-call:** *My work* shows their own cases and duties. They post what they receive and mark each one To do, In progress, Done or Need help. Help requests appear at the top of everyone's board, and anyone can tap *I'll go*.

## OT rooms
The **OT rooms** tab is a live board of every operating room for the day:
- each room shows *Running* (with time since the case started), *Between cases*, *Not started*, *List finished* or *No cases*, the case running now, the next case, and how many are finished;
- **Start next** and **Finish case** update a room in one tap (starting the next case finishes the one before); the full list per room lets you add, start, finish or cancel cases;
- emergency on-call cases booked into a room appear there too;
- **OT distribution** sets each day's rooms with their list/specialty and anaesthetist, and can copy the rooms from the previous day.
Anyone signed in with their PIN can update rooms, including consultants who are not on the on-call shift.

## Hospital overview
The **Hospital** tab shows every place anaesthesia is working on one screen, as tiles grouped by area: Main OT, cath lab and other rooms, Trauma OT, PACU, NORA areas, and the outside duties (APS / trauma / code blue, assessment, emergency call, OB/GYN). A tile is green when running, amber when waiting, grey when finished and red when someone needs help, and shows the current case, time running, progress and the anaesthetist. Tapping a tile opens that room or list. In the morning it shows the elective distribution; on call it shows only theatres with an on-call case, who holds the phone, and who is free now. Third on-calls land on this tab.

## Email sign-in with approval
The front page asks doctors to **Sign in** or **Request access**. A request gives the grade (Consultant, Senior specialist, Specialist, Senior registrar, Registrar), full name, email and a password. It waits until an admin approves it on the **Admin** tab and links it to the doctor's name on the rota (the closest name is suggested). Until then the person sees nothing of the board.

- The first admin is created by a second or third on-call who is signed in with their PIN: Admin → *Set up email sign-in*. From then on the board is private, PINs stop working, and everyone signs in with email and password.
- Admins approve or reject requests, change the linked rota name, make other approved accounts admins (there is always at least one), switch accounts off and on, and give a new password (the app makes one to send privately). Everyone can change their own password under their name at the top.
- Only admins can change the rota, teams, staff, settings, the OT distribution, room cases, prepared details and the NORA list. The server refuses such a change from anyone else. Others tick statuses, and first on-calls post the calls and cases they receive.
- Passwords are stored as bcrypt hashes; emails are kept in the accounts table, not in the board. Database: `supabase/oncall_accounts.sql`.

## Admins (before email sign-in)
Under the **Admin** tab, a second on-call names the board's admins (the first admin should add themselves). From then on only admins enter and change things: the rota, teams and staff, PINs and privacy, the OT distribution, adding or removing cases, prepared details, the NORA team and list, and all imports. Everyone else views, and ticks their own work. The admin decides with four switches what others may still do:
- a room's anaesthetist starts and finishes the cases in their own room;
- the day's NORA team marks NORA cases going, done or cancelled;
- second on-calls assign on-call work, set doctor status and make the coverage plan at night;
- anyone on shift updates free beds.

First on-calls always post the calls and cases they receive and tick their own tasks. The Admin tab also gathers the imports (week schedule, OT list with cases, NORA list) and the report. An admin cannot remove themselves while they are the only admin. Until admins are named, the access rules below apply.

## Simpler view and access by role
Each person sees the tabs their role uses every day; the rest are one tap away under **More**:
- First on-call, trainee, and staff not on call: My work · Hospital · OT rooms · NORA
- Second on-call: Hospital · Board · Coverage · Tasks · OT rooms · NORA · Rota & teams
- Third on-call and observers (head of department): Hospital · OT rooms · NORA · Board · Coverage

A **Today for …** card at the top of My work and Hospital shows the person's morning duty and duty phone, the room they are anaesthetising in (from the OT distribution), the NORA team, tonight's on-call role and list preparation.

Who can change what:
- A room's cases (start, finish, cancel, add, prepared details): that room's anaesthetist, as named in the OT distribution, plus the day's list prep and second / third on-calls.
- NORA case status and cancellations: the day's NORA team (names in the NORA team line), plus list prep and second / third on-calls. Adding, removing and importing NORA cases and setting the team: list prep and second / third on-calls.
- OT distribution, rooms and imports: list prep and second / third on-calls.
- Rota, teams, staff, PINs and the week schedule: second on-calls.
- On-call tasks: as before (first on-calls their own, second on-calls assign everything).
- Free beds: anyone signed in.

## Alerts on the phone
A new **need help** request or **code blue** on the current shift rings, vibrates and shows a red banner on every phone that has the app open. With notifications allowed it also shows a system notification while the app is in the background (on iPhone the app must be added to the Home Screen). Each phone can turn alerts off under Hospital → Alerts on this phone. A closed app cannot ring; true push notifications would need a server-side sender.

## Free beds
The Hospital tab shows free ICU, PACU and surgical HDU beds. Anyone on shift taps − / + when a bed frees up or is taken; the time and name of the last update are shown. Free beds are also included in the handover text.

## Day / week report
Hospital → Day / week report shows, for one day, 7 or 30 days: elective cases done and cancelled per room, average first-case start and lists started late, NORA cases and cancellations by reason, and on-call calls and cases by type and per doctor with time spent. It can be copied for the group chat.

## Week schedule import
**Rota & teams → Import week schedule** takes one paste for the whole week: per day a date line, the on-call slots (`APS: Fahad`), a `NORA: name – names` line for the NORA team, and OT room lines (`OT 1 | Fadhli | Fady`) for the OT rooms and their anaesthetists. A day with only NORA or room lines leaves its shifts unchanged.

## Prepared details per case
Every OT and NORA case can carry its preop "prepared" details (ASA, weight, comorbidities, airway, allergies, fasting, labs, consent, plan…). Tap **Prepared ✓** on a case to read them; anyone signed in can tap **+ Prep details** to add or edit them as `Key: value` lines. In any import, lines starting with `>` under a case are its details, e.g. `> ASA: 2`. Importing the same case again adds or updates its details without duplicating the case. Never enter patient names or file numbers.

## NORA list
The **NORA** tab holds each morning's non-OR anaesthesia list (radiology, nuclear medicine, ERCP, GI endoscopy). Cases are grouped by area with time, procedure and ward/bed. Each case is marked **Pending, Going, Done or Cancelled**; cancelling asks for the reason (common reasons in one tap, or typed). The day's team line, a summary count, a cancellations list and a copyable summary for the group chat are included. Lists are imported from text (date line, optional `Team:` line, then `time | area | procedure | ward/bed | notes`) or added case by case.

## PINs and history
- **Personal PIN:** the first time someone picks their name on a team board they set a 4–6 digit PIN; after that the name needs that PIN. Once anyone on the board has a PIN, only phones signed in with their own PIN can make changes, and the server records who really made each change. Five wrong tries lock the name for 15 minutes. A second or third on-call can reset someone's PIN under *Rota & teams*.
- **History & undo:** the server keeps earlier versions of the board for 14 days (each time a different person changes it, every 10 minutes, and before anything large is deleted). A second or third on-call can restore any of them under *Rota & teams → History & undo*; the board being replaced is kept too.
- **Private board:** a second or third on-call can make the board private (*Rota & teams → Privacy*). The team link then shows only a sign-in page; staff sign in with their name and PIN. New staff (or anyone who forgot their PIN) get a one-time **Invite** code from a second or third on-call, valid 7 days. Resetting a person signs them out everywhere and wipes the copy on their phone. 10 wrong PINs lock a name for 24 hours.
- Server side: `supabase/oncall_history_and_pins.sql`, then `supabase/oncall_private_board.sql`.

## Shared team board
In **Team & shift → Share with the team**, one doctor taps **Create team board** and sends the link to the team chat. Everyone who opens the link sees the same board, and changes appear on other phones within a few seconds. Edits made at the same time on different phones are merged, and the app keeps working offline and syncs when signal returns.

The board is stored in Supabase (table `oncall_boards`, see `supabase/oncall_boards.sql`). Anyone with the link or code can see and edit that board, so keep it inside the team and use ward/bed, never patient names or record numbers.
