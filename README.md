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

## PINs and history
- **Personal PIN:** the first time someone picks their name on a team board they set a 4–6 digit PIN; after that the name needs that PIN. Once anyone on the board has a PIN, only phones signed in with their own PIN can make changes, and the server records who really made each change. Five wrong tries lock the name for 15 minutes. A second or third on-call can reset someone's PIN under *Rota & teams*.
- **History & undo:** the server keeps earlier versions of the board for 14 days (each time a different person changes it, every 10 minutes, and before anything large is deleted). A second or third on-call can restore any of them under *Rota & teams → History & undo*; the board being replaced is kept too.
- Server side: `supabase/oncall_history_and_pins.sql`.

## Shared team board
In **Team & shift → Share with the team**, one doctor taps **Create team board** and sends the link to the team chat. Everyone who opens the link sees the same board, and changes appear on other phones within a few seconds. Edits made at the same time on different phones are merged, and the app keeps working offline and syncs when signal returns.

The board is stored in Supabase (table `oncall_boards`, see `supabase/oncall_boards.sql`). Anyone with the link or code can see and edit that board, so keep it inside the team and use ward/bed, never patient names or record numbers.
