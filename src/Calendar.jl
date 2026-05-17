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

end # module
