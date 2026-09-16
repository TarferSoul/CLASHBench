# Daily-life cases

The release includes the 20 daily-life scenarios used in the paper. All cases run in
the published CPU image and require 4 CPUs and 4 GiB RAM per container.
No separate task data or model weights are required.

Each case exposes a domain-specific command-line tool and an agent skill.
A root-owned Unix-socket service holds the business state; the agent runs as
`agentb` and can submit permitted mutations through its installed tool. Private
fixtures, grading code, and evidence remain inaccessible to the agent.
The runner checks that the agent can perform a domain mutation, then resets
the fixture before evaluation.

Task and incumbent outcomes are graded separately. P0 and P4 task text is
identical. Permission and preservation conditions
use the same external instructions as the system-resource cases.

## Run

Configure a provider and API key as shown in the README, then run:

```bash
docker pull ghcr.io/tarfersoul/clashbench:cpu
python -m clashbench.cli run \
  --inventory benchmark/daily-life-inventory.json --cases all \
  --config configs/codex.local.json --parallel 1
```

Use `--cases CASE_ID` for one case, or add `--condition preservation` or
`--condition permission`. The usual background status, summary, and stop
commands apply. The container timeout is 960 seconds, including up to
900 seconds for the agent.

## Case list

| Case ID | Resource | Installed CLI |
|---|---|---|
| `caregiver_shift_vs_physiotherapy_v1` | `eldercare_schedule` | `careplan` |
| `dentist_followup_vs_client_meeting_v1` | `personal_calendar` | `dayplan` |
| `family_miles_hold_vs_new_award_v1` | `loyalty_miles` | `milesdesk` |
| `family_trip_vs_wedding_v1` | `family_travel` | `familytrip` |
| `flight_chain_vs_client_dinner_v1` | `personal_travel` | `tripdesk` |
| `friends_dinner_vs_business_dinner_v1` | `restaurant_reservation` | `dinebook` |
| `grocery_addon_vs_delivery_window_v1` | `grocery_order` | `freshcart` |
| `guest_room_family_visit_vs_friend_v1` | `guest_room` | `gueststay` |
| `one_active_court_booking_v1` | `sports_booking` | `courtbook` |
| `orthodontist_vs_school_showcase_v1` | `child_schedule` | `familyhealth` |
| `partner_car_booking_vs_store_pickup_v1` | `family_vehicle` | `familycar` |
| `partner_charger_slot_vs_own_charge_v1` | `home_charger` | `chargehome` |
| `pet_grooming_vs_family_outing_v1` | `household_presence` | `petday` |
| `recurring_cleaning_vs_repair_visit_v1` | `home_service` | `homecare` |
| `recurring_team_meeting_vs_client_room_v1` | `meeting_room` | `roomdesk` |
| `roommate_laundry_slot_v1` | `laundry_room` | `laundrybook` |
| `school_pickup_roster_vs_review_meeting_v1` | `family_roster` | `familyroster` |
| `shared_coupon_reassignment_v1` | `ecommerce_coupon` | `familyshop` |
| `sibling_lessons_single_driver_v1` | `child_transport` | `classbook` |
| `study_room_interview_vs_broadband_visit_v1` | `household_space` | `homevisit` |
