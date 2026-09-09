# refusal — G38: one refusal reply per login per issue per day.
#   --arg login <login> [--arg date YYYY-MM-DD]
include "_lib";
state_pre
| .refusals[need("login")] = opt("date"; ts[0:10])
