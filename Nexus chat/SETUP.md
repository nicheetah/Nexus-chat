# NEXUS CHAT: uko wo gushyira ku murongo (setup)

Dosiye zose ziri muri iyi folder zigomba kujya hamwe ku **HTTPS** (Netlify, Vercel, Cloudflare Pages, GitHub Pages...):
`index.html`, `sw.js`, `manifest.webmanifest`, `icon-192.png`, `icon-512.png`, `icon-maskable-512.png`.

## 1. Database (Supabase)
1. Supabase Dashboard → **SQL Editor** → shyiramo `supabase-setup.sql` yose → **Run**. Irasubirwamo nta kibazo, kandi mbere yo guhindura ikora backup (`backup_<table>_<itariki>`).
2. **Realtime → Settings** → zimya **"Allow public access"** (kugira ngo typing/online bikoreshe private channels).
3. Muri `index.html` shyiramo `SUPABASE_URL` na `SUPABASE_ANON_KEY` (anon/publishable key gusa).

## 2. Ibijyanye na passwords
- Passwords ntizibikwa muri tables zacu. Supabase Auth ibika **bcrypt hash** gusa muri `auth.users`; nta muntu wazisoma, ndetse natwe ntitwazibona.
- Dashboard → **Authentication**:
  - **Providers → Email**: shyiraho *Minimum password length = 8*, ukore *Confirm email* (production), uzimye *Allow anonymous sign-ins* niba utayikeneye.
  - **Sign In / Providers → Password security**: ushobora gufungura *Prevent use of leaked passwords* (Pro plan).
  - **URL Configuration**: *Site URL* = aho wasohoye app (urugero `https://nexus.example.com/`) kandi wongere iyo URL muri *Redirect URLs*. **Ibi ni ngombwa ku buryo bwo "Forgot password"** kugira ngo link ya email ikugarure kuri app.
- Muri app: kwiyandikisha bisaba ≥8 characters (inyuguti + imibare), hari "Forgot password?", guhindura password muri Profile, na 👁 yo kureba password wandika.

## 3. Push notifications (ubutumwa buza app ifunze)
1. Kora VAPID keys: `npx web-push generate-vapid-keys`
2. **Public key** shyira muri `index.html` → `VAPID_PUBLIC_KEY`. **Private key** ntukayishyire muri index.html.
3. Muri terminal (Supabase CLI, `supabase login` + `supabase link`):
   ```
   supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:you@example.com WEBHOOK_SECRET=<ijambo-rirerire-ryihariye>
   supabase functions deploy send-push --no-verify-jwt
   ```
4. Dashboard → **Database → Webhooks** → kora webhook **ebyiri** (HTTP Request, POST):
   | Table | Event | URL | Header |
   |---|---|---|---|
   | `messages` | Insert | `https://<project-ref>.supabase.co/functions/v1/send-push` | `x-webhook-secret: <WEBHOOK_SECRET>` |
   | `call_signals` | Insert | (URL imwe) | (header imwe) |
5. Muri app: Profile → **🔔 Notifications**. **iPhone**: banza Share → *Add to Home Screen*, ufungure app ivuye kuri home screen (iOS 16.4+).

## 4. Calls (TURN)
`index.html` isanzwe ifite TURN y'ubuntu ya *Open Relay* yo **kugerageza gusa** (ni iyo gusangira, ishobora kuzura). Mbere yo gutangira gukoresha n'abantu benshi, shyiramo TURN yawe muri `TURN_SERVERS` (Metered, Twilio, Cloudflare Calls TURN, cyangwa coturn).

## 5. Contacts
- **Android Chrome**: buto *Pick from phone contacts*.
- **iPhone / izindi browsers**: *Import contacts file* (.vcf cyangwa .csv ya Google/Outlook), cyangwa andika numero yose mu gasanduku ko gushakisha.
- Gushakisha numero bifite igipimo: 3000 ku munsi kuri buri muntu, 500 icyarimwe.

## Imbibi (limits) zitavaho n'code
- **50 MB kuri buri dosiye** ni ntarengwa ya Supabase Free. Pro plan: Dashboard → Storage → Settings, hanyuma uzamure `file_size_limit` muri SQL na `MAX_FILE` muri index.html.
- Media z'ubutumwa ni **private** (signed links); Shorts n'amafoto ya profile ni **public** by design.
