module Calendar

using Dates

# Computes the date of Easter Sunday (Gregorian) using the Anonymous (Meeus/Jones/
# Butcher) algorithm. Source: https://en.wikipedia.org/wiki/Date_of_Easter
function easter_sunday(year::Integer)::Date
    a = year % 19
    b = year ÷ 100
    c = year % 100
    d = b ÷ 4
    e = b % 4
    f = (b + 8) ÷ 25
    g = (b - f + 1) ÷ 3
    h = (19a + b - d - g + 15) % 30
    i = c ÷ 4
    k = c % 4
    l = (32 + 2e + 2i - h - k) % 7
    m = (a + 11h + 22l) ÷ 451
    month_ = (h + l - 7m + 114) ÷ 31
    day_ = ((h + l - 7m + 114) % 31) + 1
    return Date(year, month_, day_)
end

# wd is 1=Mon ... 7=Sun (Dates.Mon, Dates.Tue, ...).
function first_weekday(year::Integer, month::Integer, wd::Integer)
    d = Date(year, month, 1)
    while dayofweek(d) != wd
        d += Day(1)
    end
    return d
end

function last_weekday(year::Integer, month::Integer, wd::Integer)
    d = lastdayofmonth(Date(year, month, 1))
    while dayofweek(d) != wd
        d -= Day(1)
    end
    return d
end

function nth_weekday(year::Integer, month::Integer, wd::Integer, n::Integer)
    first = first_weekday(year, month, wd)
    return first + Week(n - 1)
end

"""
    holidays_ie(year)

Irish public holidays for the given year. Includes the St Brigid's Day holiday
introduced in 2023.
"""
function holidays_ie(year::Integer)::Set{Date}
    easter = easter_sunday(year)
    dates = Date[
        Date(year, 1, 1),                              # New Year's Day
        easter + Day(1),                               # Easter Monday
        first_weekday(year, 5, Dates.Mon),             # May Day (first Mon May)
        first_weekday(year, 6, Dates.Mon),             # June Bank Holiday
        first_weekday(year, 8, Dates.Mon),             # August Bank Holiday
        last_weekday(year, 10, Dates.Mon),             # October Bank Holiday
        Date(year, 12, 25),                            # Christmas Day
        Date(year, 12, 26),                            # St Stephen's Day
    ]
    if year >= 2023
        # St Brigid's Day: first Mon Feb, or 1 Feb if it falls on a Fri.
        feb1 = Date(year, 2, 1)
        push!(dates, dayofweek(feb1) == Dates.Fri ?
                     feb1 : first_weekday(year, 2, Dates.Mon))
    end
    return Set(dates)
end

"""
    holidays_uk(year)

England & Wales bank holidays (NI shares most; we treat the GB set as a
demand-relevant calendar for cross-border effects).
"""
function holidays_uk(year::Integer)::Set{Date}
    easter = easter_sunday(year)
    dates = Date[
        Date(year, 1, 1),                              # New Year's Day
        easter - Day(2),                               # Good Friday
        easter + Day(1),                               # Easter Monday
        first_weekday(year, 5, Dates.Mon),             # Early May Bank Holiday
        last_weekday(year, 5, Dates.Mon),              # Spring Bank Holiday
        last_weekday(year, 8, Dates.Mon),              # Summer Bank Holiday
        Date(year, 12, 25),                            # Christmas Day
        Date(year, 12, 26),                            # Boxing Day
    ]
    # NI-specific (St Patrick's Day, Orangemen's Day) — relevant for SEM demand.
    push!(dates, Date(year, 3, 17))                    # St Patrick's Day
    push!(dates, Date(year, 7, 12))                    # Battle of the Boyne
    return Set(dates)
end

function is_holiday_ie(d::Date)
    d ∈ holidays_ie(year(d))
end

function is_holiday_uk(d::Date)
    d ∈ holidays_uk(year(d))
end

# --------------------------------------------------------------------------
# Holiday-neighborhood features
# --------------------------------------------------------------------------
#
# These don't need any new data — they're derived from the existing holiday
# sets. The day-before and day-after a holiday have *different* demand from
# either a normal day or the holiday itself, so the model benefits from
# knowing where in the holiday neighbourhood it is.

"""
    is_holiday_either(d) -> Bool

True if `d` is an IE or UK public holiday.
"""
is_holiday_either(d::Date) = is_holiday_ie(d) || is_holiday_uk(d)

"""
    is_holiday_eve(d) -> Bool

True if `d + 1` is a holiday (either IE or UK).
"""
is_holiday_eve(d::Date) = is_holiday_either(d + Day(1))

"""
    is_post_holiday(d) -> Bool

True if `d - 1` is a holiday.
"""
is_post_holiday(d::Date) = is_holiday_either(d - Day(1))

"""
    days_to_next_holiday(d; max_look = 14) -> Int

Number of days until the next IE or UK holiday. Capped at `max_look`.
"""
function days_to_next_holiday(d::Date; max_look::Int = 14)
    for k in 1:max_look
        is_holiday_either(d + Day(k)) && return k
    end
    return max_look
end

"""
    days_since_last_holiday(d; max_look = 14) -> Int

Number of days since the most recent IE or UK holiday. Capped at `max_look`.
"""
function days_since_last_holiday(d::Date; max_look::Int = 14)
    for k in 1:max_look
        is_holiday_either(d - Day(k)) && return k
    end
    return max_look
end

"""
    is_bridge_day(d) -> Bool

A weekday sandwiched between a holiday/weekend and a holiday/weekend on the
other side. The classic case: Tuesday after a Monday holiday is NOT a bridge;
Friday between a Thursday holiday and the weekend IS.
"""
function is_bridge_day(d::Date)
    dayofweek(d) > 5 && return false          # weekends are not bridge days
    is_holiday_either(d) && return false      # holidays themselves aren't
    prev_off = (dayofweek(d - Day(1)) > 5) || is_holiday_either(d - Day(1))
    next_off = (dayofweek(d + Day(1)) > 5) || is_holiday_either(d + Day(1))
    return prev_off && next_off
end

# --------------------------------------------------------------------------
# DST transition features
# --------------------------------------------------------------------------
#
# DAM forecasters routinely blow up on the 23- and 25-hour transition days
# because the lag features misalign with the new clock. We give the model
# explicit flags.
#
# EU DST: starts last Sun in March 01:00 UTC, ends last Sun in October 01:00 UTC.

"""
    dst_start(year) -> Date
"""
dst_start(year::Integer) = last_weekday(year, 3, Dates.Sun)

"""
    dst_end(year) -> Date
"""
dst_end(year::Integer) = last_weekday(year, 10, Dates.Sun)

"""
    is_dst_transition_day(d) -> Bool

True if `d` is a DST transition (spring forward or fall back).
"""
function is_dst_transition_day(d::Date)
    y = year(d)
    return d == dst_start(y) || d == dst_end(y)
end

"""
    days_since_dst_change(d; max_look = 14) -> Int

Number of days since the most recent DST transition, capped at `max_look`.
A small integer here means the model's lag features may be misaligned with
the new local clock.
"""
function days_since_dst_change(d::Date; max_look::Int = 14)
    y = year(d)
    candidates = [dst_start(y), dst_end(y),
                  dst_start(y - 1), dst_end(y - 1)]
    past = [d - c for c in candidates if d >= c]
    isempty(past) && return max_look
    delta = minimum(past).value
    return min(delta, max_look)
end

end # module
