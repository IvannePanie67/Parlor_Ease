# ParlorEase — Calm Green Edition

## Run locally
1. Extract this folder.
2. Open `index.html` in a browser, or use VS Code Live Server.
3. The landing page opens first. Use **Book a visit** to open customer registration/login.
4. The app is connected to Supabase through `supabase-client.js` (URL and publishable key are set at the top of that file).

## Supabase database setup
1. Create a project at https://supabase.com/dashboard.
2. Open **SQL Editor → New query**.
3. Paste and run `supabase-schema.sql`.
4. In **Authentication → Users**, create your own account (or sign up from the app after Supabase Auth is wired in).
5. Promote the intended administrator by running the commented SQL at the bottom of `supabase-schema.sql`, replacing the email with the actual admin email.
6. In **Project Settings → API**, copy the Project URL and public anon/publishable key. Never put a `service_role` key in browser JavaScript or commit it to this project.
7. Run `supabase-patch.sql` once after the schema (adds staff email, double-booking guard, extra policies).
8. In **Authentication → Providers → Email**, turn off **Confirm email** for classroom demos (or keep it on and confirm by email).
9. Register in the app, then run the admin promotion SQL. New staff: admin adds them in Staff with their email, they register with that email, then admin re-saves the staff record.

## Tables created
- `profiles` — Auth-linked identity and role
- `customers` — customer contact details and visit count
- `staff` — staff directory and availability
- `services` — service catalog, prices, durations, and image URLs
- `appointments` — bookings and statuses
- `transactions` — payments and receipts
- `service_queue` — queue entries, priority, and state

RLS is enabled on all tables. Review and test policies before using real customer data. For a production app, tighten role assignment and verify all policies against the exact workflows you enable.

## Final-project checklist from the supplied criteria
- Functional interface and distinct customer/staff/admin experiences
- Add, update, delete, and display operations for management pages
- Search and sorting controls on data tables
- Validation on forms and constrained database fields
- Persistent storage: Supabase (PostgreSQL) with Auth and row-level security
- DSA explanation should still be prepared separately for at least four data structures and four algorithms, including where each is used and why it was selected.
