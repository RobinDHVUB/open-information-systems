-- Open Information Systems
-- Part 2 - Database System
-- Robin De Haes (0547560)

/*
Remarks
-------

We didn't always go for the most complicated queries or even for the most efficient queries, but we instead tried to find a
good tradeoff between complexity, efficiency and readability while still clearly demonstrating the functionality of our suggested system.
*/

/*
FEATURE 1: Flight Searches
--------------------------


Potential passengers might want to perform advanced flight searches to find flights that fulfill all their needs. 
As a use case we present the following search query in which a passenger is looking to make a booking:
- between Brussels Airport and JFK Airport
- for a round-trip (i.e. an outward and return flight should be found)
- that only has direct flights (no layovers)
- that takes place in October 2022
- and has a maximum flight duration of 16 hours
- on flights that still have a first class window seat available
- and also have a vegan meal option
- with at least 5 days in between departure and arrival 
  (since the passenger wants to stay at the destination for at least a week)
The results should be ordered on flight departure time.

-- Expected output:
-- ° SN5555 are direct flights from BRU to JFK and SN5556 are direct flights from JFK to BRU.
--   These flights are organized in August, October and December, but only the October ones should be shown.
-- ° SN8555 is a direct flight from BRU to JFK in October but it has a duration of 17 hours so it should not be included.
-- ° SN7555 is a short, direct flight from BRU to JFK in October but it is only 4 days away from any possible return flight so it should not be included.
-- ° SN1555 is a valid flight timewise, but it doesn't offer vegan meals.
-- ° SN9555 fulfills all other requirements but doesn't have a first class window seat available anymore.
--
-- So finally, we only expect the following flight combinations to be returned:
-- SN5555 departing to JFK on 2022-10-03 10:00:00 - SN5556 departing to BRU on 2022-10-10 8:00:00
-- SN5555 departing to JFK on 2022-10-03 10:00:00 - SN5556 departing to BRU on 2022-10-17 8:00:00
-- SN5555 departing to JFK on 2022-10-10 10:00:00 - SN5556 departing to BRU on 2022-10-17 8:00:00

*/

-- For clarity and readability, we first filter the outward and return flights on the shared constraints in a subquery
-- and then add constraints to connect the outward and return flight

-- This subquery filters the flight table on a set of common constraints to more easily extract the outward and return flight later. 
-- A common table expression is used for readability reasons.
WITH filtered_flights AS (
	SELECT
		-- relevant flight information that will be used later on
		f.departure_airport_iata AS origin_airport,
		f.arrival_airport_iata AS destination_airport,
		f.flight_designator AS flight_nr, 
		f.departure_date_time AS departure, 
		f.arrival_date_time AS arrival, 
		f.arrival_date_time - f.departure_date_time AS duration
	FROM flight AS f
	WHERE 
		-- filter all flights to only keep flights between the two specified airports
		((f.departure_airport_iata = 'BRU' AND f.arrival_airport_iata = 'JFK')
		 OR (f.departure_airport_iata = 'JFK' AND f.arrival_airport_iata = 'BRU'))
		-- we want to travel in October 2022
		AND f.departure_date_time::date >= '2022-10-01' AND f.arrival_date_time::date <= '2022-10-31'
		-- the maximum duration of the flight should be below 16 hours
		AND f.arrival_date_time - f.departure_date_time < '16:00:00'
		-- the flight should offer a vegan meal
		AND EXISTS (
			SELECT 1
			FROM meal_service AS ms
			JOIN flight_meal_service AS fms ON fms.meal_name = ms.meal_name
			WHERE fms.flight_designator = f.flight_designator AND fms.flight_departure_date_time = f.departure_date_time
			AND ms.meal_type = 'vegan' )
		-- there should be at least 1 first class seat still available on the flight
		AND (
			-- compute the available seats by first counting the number of first class seats on the plane
			-- and then subtracting the number of first class bookings for this flight
			(SELECT COUNT(*) 
			 FROM seat AS s 
			 WHERE s.airplane_tail_number = f.airplane_tail_number 
			 AND s.price_class = 'first')
			-
			(SELECT COUNT(*) 
			 FROM booking AS b
			 JOIN booking_flight AS bf 
			 	ON 	b.booking_number = bf.booking_number
					AND bf.flight_designator = f.flight_designator AND bf.departure_date_time = f.departure_date_time 
			 JOIN booking_for_passenger AS bfp ON bfp.booking_number = b.booking_number
			 WHERE b.price_class = 'first')) > 0 
		-- ... and not all window seats should be reserved
		AND (SELECT COUNT(*) 
			 FROM seat AS s 
			 WHERE s.airplane_tail_number = f.airplane_tail_number 
			 AND s.price_class = 'first'
			 AND s.seat_type = 'window'
			 AND NOT EXISTS ( 
				 -- check if the seat is already reserved
				 SELECT 1 
				 FROM seat_reservation AS sr
				 JOIN booking_flight AS bf 
				 	ON bf.flight_designator = f.flight_designator AND bf.departure_date_time = f.departure_date_time 
				 WHERE sr.seat_tail_number = f.airplane_tail_number 
				 AND sr.seat_number = s.seat_number
				 AND sr.booking_number = bf.booking_number)) > 0
)
SELECT 
	-- outward flight information that should be shown
	CONCAT(outward_flight.origin_airport, '->', outward_flight.destination_airport) as out_flight,
	outward_flight.flight_nr as out_flight_nr,
	outward_flight.departure as out_departure,
	outward_flight.arrival as out_arrival,
	outward_flight.duration as out_duration,
	-- return flight information that should be shown
	CONCAT(return_flight.origin_airport, '->', return_flight.destination_airport) as ret_flight,
	return_flight.flight_nr as ret_flight_nr,
	return_flight.departure as ret_departure,
	return_flight.arrival as ret_arrival,
	return_flight.duration as ret_duration
FROM filtered_flights AS outward_flight
JOIN filtered_flights AS return_flight 
	-- we are looking for round-trip flights
	ON (return_flight.origin_airport = outward_flight.destination_airport
	    AND return_flight.destination_airport = outward_flight.origin_airport)
WHERE outward_flight.origin_airport = 'BRU' AND outward_flight.destination_airport = 'JFK'
	-- the passenger wants to stay at the destination for at least 5 days
	AND return_flight.departure::date > (outward_flight.arrival::date + INTERVAL '5 days') 
ORDER BY out_departure, ret_departure ;

/*
FEATURE 2: Overbooking Mitigation
---------------------------------

If too many overbookings occurred, a handling agent might need to upgrade a passenger. To decide which passenger should be 
upgraded, the number of frequent flyer points for Miles & More is used.

As a use case we present a query in which we are looking for the following type of passenger on the overbooked flight
SN1510 that departs on 2022-08-20 11:30:00:
- he/she booked an economy seat (since business class is not overbooked)
- he/she is a frequent flyer with Miles & More, a loyalty program supporting upgrades to first class 
  (since business class is fully booked too, just not overbooked)
- he/she has the most frequent flyer points of the possible passengers to upgrade
- he/she is not a minor
- he/she is not accompanying minor(s) as the only adult (since we would need to upgrade the minors too then)
The results should be ordered in a descending fashion on frequent flyer points.

-- Expected output:
-- ° There are 18 passengers booked on the specified flight, but 2 of them are in business class so they are excluded.
-- ° Of the 16 passengers that are left, 6 don't have a frequent flyer card for Miles & More which is the only one
--   supporting an upgrade to first class.
-- ° P00000074332 is an accompanied minor, so she is excluded.
-- ° P00000074333 is the only adult that is accompanying minor P00000074332, so she is excluded.
-- ° There are 8 eligible passengers left of which P00000074323 and P00000074324 both have the most points (25000).
--   However, P00000074324 made his booking first so he should appear first (and be selected for the upgrade).
--   Furthermore, passenger P00000074501 doesn't have an email specified, so the email of the booker is shown for him which is passenger P00000074323.
*/

SELECT 
	pr.passenger_id as passenger_id, 
	-- only the booker (i.e. main contact is required to provide an email address)
	-- so if the selected passenger has no direct contact information we return the main contact's information
	CASE 
		WHEN pr.email IS NOT NULL
		THEN pr.email 
		ELSE (SELECT booker.email
			  FROM passenger booker
			  WHERE booker.passenger_id = b.passenger_id)
	END,
	ffc.loyalty_program_name, 
	ffc.points,
	b.booking_date_time
FROM passenger AS pr
JOIN booking_for_passenger AS bfp ON bfp.passenger_id = pr.passenger_id
JOIN booking AS b ON b.booking_number = bfp.booking_number
-- we are checking a specific flight
JOIN flight AS f ON f.flight_designator = 'SN1510' AND f.departure_date_time = '2022-08-20 11:30:00'
JOIN booking_flight AS bf 
	ON bf.booking_number = b.booking_number 
	   AND bf.flight_designator = f.flight_designator AND bf.departure_date_time = f.departure_date_time
JOIN loyalty_program AS lp ON lp.program_name = 'Miles & More'
JOIN frequent_flyer_card AS ffc ON ffc.passenger_id = pr.passenger_id AND lp.program_name = ffc.loyalty_program_name
JOIN award_ticket AS awt ON awt.loyalty_program_name = lp.program_name
-- economy is overbooked, so we are looking for passengers with such a booking
WHERE b.price_class = 'economy'
	-- we won't give an upgrade to minors (because they have to be accompanied by their adult)
	AND date_part('year', age(pr.date_of_birth)) >= 12
	-- we will check whether the loyalty program they have a frequent flyer card from supports
	-- upgrades to first class (because business class is already fully booked as well)
	AND awt.upgrade_type = 'first class'
	-- we won't give an upgrade to an adult if it's the only adult accompanying a minor
	AND EXISTS(
		SELECT 1
		FROM passenger AS epr
		JOIN booking_for_passenger AS ebfp ON ebfp.passenger_id = epr.passenger_id AND ebfp.booking_number = b.booking_number
		-- to be eligible you should not be accompanying a minor or there should be more than 1 adult accompanying the minor(s)
		HAVING COUNT(date_part('year', age(epr.date_of_birth)) < 12 OR NULL) = 0 
			   OR COUNT(date_part('year', age(epr.date_of_birth)) >= 18 OR NULL) > 1)
ORDER BY ffc.points DESC, b.booking_date_time ;

/*
FEATURE 3: Booking Price & Awarded Points
-----------------------------------------

The total price for a booking consists of many different parts, such as flight price, luggage price, insurance price, seat reservation price, etc.
Both a passenger and a handling agent can benefit from being able to compute this price (and perhaps get a decomposition into the different parts).
As a use case we will compute and show the total booking price, way of payment and awarded points for the booking with booking_number B00000000017.
The following query would actually give a correct and complete overview per booking if we remove the booking_number constraint, 
e.g., by replacing "b.booking_number = 'B00000000017'" with "b.booking_number IS NOT NULL".
However, for clarity we limited the computation to one specific order.

-- Expected output:
-- ° B00000000017 is for a round-trip and therefore the total price should also consider the options taken for the return trip B00000000018.
-- ° There are 3 passengers included in the booking (P00000074333, P00000074332 and P00000074324) with P00000074333 being the booker.
-- ° P00000074333:
--   OUTWARD
--   * Flight Price: 213 (for one person)
--   * Free carry-on luggage + 1 Heavy bag of 50: 50
--   * Insurance: 119.13 (for the whole group)
--   * Seat Reservation: 17
--   RETURN
--   * Flight Price: 220 (for one person)
--   * Free carry-on luggage + 2 Heavy bags of 50: 100
--   * Seat Reservation: 17
--   SUBTOTAL = 213 + 50 + 119.13 + 17 + 220 + 100 + 17 = 736.13
-- ° P00000074332:
--   OUTWARD
--   * Flight Price: 213 (for one person)
--   * Free carry-on luggage: 0
--   * Seat Reservation: 17
--   RETURN
--   * Flight Price: 220 (for one person)
--   * Free carry-on luggage: 0
--   * Seat Reservation: 17
--   SUBTOTAL = 213 + 17 + 220 + 17 = 467
-- ° P00000074324:
--   OUTWARD
--   * Flight Price: 213 (for one person)
--   * Free carry-on luggage: 0
--   RETURN
--   * Flight Price: 220 (for one person)
--   * Free carry-on luggage: 0
--   SUBTOTAL = 213 + 220 = 433
-- ° BOOKING PRICE = 736.13 + 467 + 433 = 1636.13
--   PAYMENT TYPE = maestro
--   AWARDED POINTS = 4513 (Miles & More)
*/


-- To also clearly show a possible decomposition of the costs per passenger we first present a subquery that would provide
-- an overview of the costs per passenger. We then later sum everything up to compute the total cost.
-- To get a decomposing overview per passenger, the subquery can also be executed separately. 

-- This subquery computes the price per passenger for different parts of the bill, 
-- with parts of the bill being insurance, luggage, flight cost, etc.
-- COALESCE is used to show a cost of 0.0 if a certain part would be missing (i.e. is not used in this booking)
WITH q AS (
	SELECT 
		pr.passenger_id AS passenger, 
		b.booking_number AS booking,
		po.payment_type AS payment,
		-- we also keep track of the actual booker, 
		-- since it is the passenger that will be awarded the frequent flyer miles (in case of a group booking)
		b.passenger_id AS booker,
		-- insurance only has to be paid once per group per complete trip 
		-- (even if it's a round-trip, we don't have separate insurance for the return booking)
		COALESCE(i.price, 0.0) AS insurance_cost,
		-- outward flight:
		-- the price for the actual flight itself (i.e. transportation of the passenger) is stored on the booking 
		b.flights_price AS out_flight_cost,  
		-- the price for bringing luggage can be computed by summing up 
		-- the number of bags we have of each type times the cost for that type of bag
		COALESCE(SUM(lr.number_of_bags * lo.price), 0.0) AS out_luggage_cost, 
		-- the price for reserving a seat is stored via a seat reservation
		COALESCE(sr.price, 0.0) AS out_seat_cost,
		-- return flight:
		COALESCE(ret_b.flights_price, 0.0) AS ret_flight_cost,
		-- we compute the luggage price directly from the required tables here for the return booking, since an additional LEFT JOIN
		-- would lead to duplicate results in combination with the LEFT JOIN for luggage on the outward booking
		COALESCE(
			(SELECT SUM(ret_lr.number_of_bags * ret_lo.price)
			 FROM luggage_reservation AS ret_lr
			 JOIN luggage_service AS ret_lo ON ret_lo.luggage_type = ret_lr.luggage_service_type
			 WHERE ret_lr.booking_number = ret_b.booking_number 
				   AND ret_lr.passenger_id = pr.passenger_id), 0.0) AS ret_luggage_cost,
		COALESCE(ret_sr.price, 0.0) AS ret_seat_cost
	FROM passenger AS pr
	-- we are computing the total cost for a specific booking
	JOIN booking AS b ON b.booking_number = 'B00000000017'
	JOIN booking_for_passenger AS bfp ON (bfp.booking_number = b.booking_number AND bfp.passenger_id = pr.passenger_id)
	-- also show how everything was paid for
	JOIN payment_option AS po ON po.account_number = b.payment_option_account_number
	-- LEFT JOIN is used since all these parts are optional parts in a booking
	-- the group insurance is only charged to the booker (and only once for the whole round-trip)
	LEFT JOIN insurance AS i 
		ON (i.company_name = b.insurance_company_name AND i.product_name = b.insurance_product_name
			AND pr.passenger_id = b.passenger_id)
	-- total luggage price for the passenger needs the number of bags of each type of luggage for this passenger
	LEFT JOIN luggage_reservation AS lr ON lr.booking_number = b.booking_number AND lr.passenger_id = pr.passenger_id
	LEFT JOIN luggage_service AS lo ON lo.luggage_type = lr.luggage_service_type
	-- seat reservation price for this passenger can be directly taken from the seat reservation
	LEFT JOIN seat_reservation AS sr ON (sr.passenger_id = pr.passenger_id AND sr.booking_number = b.booking_number)
	-- additional costs can be attached to the return booking 
	-- (luggage cost for the return booking is computed directly in the SELECT statement above)
	LEFT JOIN booking AS ret_b ON b.return_booking_number = ret_b.booking_number
	-- seat reservation price for this passenger for the return booking can be directly taken from the seat reservation
	LEFT JOIN seat_reservation AS ret_sr ON (ret_sr.passenger_id = pr.passenger_id AND ret_sr.booking_number = ret_b.booking_number)
	-- ensure this query is only executed for the main booking and not separately for the return part
	-- (this is only added to filter out unwanted results in case a full booking overview is requested instead of prefiltering on
    --  'B00000000017')
	WHERE NOT EXISTS (SELECT 1 FROM booking WHERE booking.return_booking_number = b.booking_number)
	-- except for luggage cost, all prices are unique and can therefore be safely included in the GROUP BY statement
	GROUP BY b.booking_number, ret_b.booking_number, pr.passenger_id, po.payment_type, b.flights_price, i.price, sr.price, ret_b.flights_price, ret_sr.price
)
SELECT 
	q.booking,
	q.booker,
	-- the total cost of the booking can be computed by summing up all the separate parts for all the passengers in the booking
	ROUND(CAST(SUM(q.insurance_cost) 
			   + SUM(q.out_flight_cost) 
			   + SUM(q.out_luggage_cost)
			   + SUM(q.out_seat_cost) 
			   + SUM(q.ret_flight_cost) 
			   + SUM(q.ret_luggage_cost) 
			   + SUM(q.ret_seat_cost) AS numeric), 2) AS total_price,
	q.payment,
	-- the number of awarded points for this booking are shown as well
	ffc.loyalty_program_name AS loyalty_program,
	ap.points AS awarded_points
FROM q
-- LEFT JOIN since having a frequent flyer card is optional
-- awarded points are directly connected to the booking
LEFT JOIN awarded_points AS ap ON ap.booking_number = q.booking
-- via the frequent flyer card the name of the loyalty program can be displayed as well
LEFT JOIN frequent_flyer_card AS ffc ON (ffc.passenger_id = q.booker AND ffc.frequent_flyer_number = ap.frequent_flyer_number)
-- all these fields are unique and can therefore be safely included in the GROUP BY statement
GROUP BY q.booking, q.booker, q.payment, ffc.loyalty_program_name, ap.points ;

/*
FEATURE 4: Cost Computations
----------------------------

Multiple planes might be available for a certain flight, but not all of them might be equally cost-effective. To be able to efficiently compare planes for a
flight an airline agent would benefit from being able to find eligible planes and estimate their fuel cost. Although in reality more factors than fuel costs 
are used to decide which plane is chosen for a flight, we will present an example that filters planes on eligibility and then orders them on fuel cost 
in order to make a decision.

As a use case we present a query that gives a fuel cost overview of all planes that would be eligible for flight SN4508 from Brussels to Sofia 
that departs on 2022-10-01 13:15:00 and currently has 3 economy seats, 1 business seat and 1 first class seat booked.
To be eligible for this flight, the plane:
- should be able to fly the necessary distance
- should be fast enough to reach the destination in a similar time
- should be able to accommodate all booked passengers (in their chosen price class)
The results should be ordered on estimated fuel costs.

-- Expected output:
-- ° There are 5 different types of aircraft, with 3 of them using kerosene and 2 using gasoline.
-- ° All aircrafts would fly fast enough, but the KING AIR B200 cannot fly far enough and therefore these planes are excluded
-- ° The CITATION CJ3 only has business seats and thus cannot accommodate the economy passengers. Therefore, it is excluded.
-- ° The AIRBUS A319 and A320 only have economy seats and are therefore excluded as well.
-- ° This only leaves the aircraft type Airbus A330-300 as possible plane type for this trip. 
--   There are 4 planes of this type with the same properties overall, but O-BAJJ is the newest one which gives it better fuel economy
--   (i.e. it uses less fuel and it thus has lower fuel costs). 
--   We expect the overview to contain 4 planes of the type Airbus A330-300 with O-BAJJ being at the top. 
*/

-- For clarity and readability, we use a subquery to compute the number of economy, business and first class seats 
-- that are required to seat all passengers that currently booked the specified flight.

-- This subquery counts the numbers of booked seats per price class.
-- A common table expression is used for readability reasons.
WITH booked_seats AS (
	-- we have to count for how many passengers a seat is booked for the specified flight
	SELECT b.price_class, COUNT(*) AS seat_count
	FROM booking_for_passenger AS bfp
	JOIN booking_flight AS bf ON bf.booking_number = bfp.booking_number
	JOIN booking AS b ON b.booking_number = bf.booking_number
	-- we are counting the seats for a specific (known) flight
	WHERE bf.flight_designator = 'SN4508' AND bf.departure_date_time = '2022-10-01 13:15:00' 
	GROUP BY b.price_class)
SELECT 
		ap.tail_number,
		ap.aircraft_type,
		-- we use a different (arbitrarily chosen) price for a liter of kerosene and gasoline
		-- and use that price to compute the fuel cost of the plane
		ROUND(CAST(CASE 
					   WHEN ap.fuel_type = 'kerosene'
					   THEN (f.distance / ap.fuel_economy) * 0.4
					   ELSE (f.distance / ap.fuel_economy) * 1.4
				   END AS numeric), 2) AS fuel_cost
FROM airplane AS ap
-- we will use flight information to put some constraints on the eligibility of airplanes
JOIN flight AS f ON (f.flight_designator = 'SN4508' AND f.departure_date_time = '2022-10-01 13:15:00')
-- the airplane should have enough fuel to cover the required distance
WHERE ap.fuel_capacity > (f.distance / ap.fuel_economy)
	-- the airplane should be able to travel fast enough so it won't arrive late
	AND ((f.distance / ap.cruising_speed) * 3600) < EXTRACT(epoch FROM f.arrival_date_time - f.departure_date_time) 
	-- the airplane should have enough economy, business and first class seats available to cover the existing bookings
	AND (SELECT COUNT(*) FROM seat AS s WHERE s.price_class = 'economy' AND s.airplane_tail_number = ap.tail_number) 
		> (SELECT seat_count FROM booked_seats AS bs WHERE bs.price_class = 'economy')
	AND (SELECT COUNT(*) FROM seat AS s WHERE s.price_class = 'business' AND s.airplane_tail_number = ap.tail_number) 
		> (SELECT seat_count FROM booked_seats AS bs WHERE bs.price_class = 'business')
	AND (SELECT COUNT(*) FROM seat AS s WHERE s.price_class = 'first' AND s.airplane_tail_number = ap.tail_number) 
		> (SELECT seat_count FROM booked_seats AS bs WHERE bs.price_class = 'first')
-- we are currently mainly using fuel cost to make our final decision, so we order on fuel cost
ORDER by fuel_cost ;

/*
FEATURE 5: Flight Overview
--------------------------

Getting an overview of possible flights that are currently offered in combination with some properties can be beneficial for both airline 
agents and potential passengers. 

As a use case we present a query that gives an overview of all flights leaving from BRU. Both direct flights and flights with layovers should be shown.
To get a better view on the type of offerings the type of flight, i.e., continental or intercontinental, will also be included.

-- Expected output:
-- ° Direct flights can be straightforwardly taken from the flights table. 
--   There should be 7 direct flights of which 2 are intercontinental:
--   * BRU -> HAM: continental, destination is in Germany (Europe)
--   * BRU -> LED: continental, destination is in Russia (Europe)
--   * BRU -> SOF: continental, destination is in Bulgary (Europe)
--   * BRU -> STN: continental, destination is in London (Europe)
--   * BRU -> TLS: continental, destination is in France (Europe)
--   * BRU -> JFK: intercontinental, destination is in USA (North-America)
--   * BRU -> MTY: intercontinental, destination is in Mexico (South-America)
-- ° All flights with layovers from BRU will go through HAM.
--   From HAM there are 3 flights possible: HAM -> JFK, HAM -> MEL and HAM -> JNB. 
--   All 3 of them are intercontinental, respectively going to North-America, Oceania and Africa.
--   HAM has a minimum connection time of 45 minutes so flights should have at least this time between them to be considered a possible connection.
--   * BRU -> HAM with flight SN1500 departing at 2022-08-20 09:00:00 and arriving at 2022-08-20 10:30:00
--     HAM -> JFK with flight SN1510 departing at 2022-08-20 11:30:00
--     There is 1 hour between them and they are less than 20 hours apart, so BRU -> HAM -> JFK is a valid flight sequence.
--   * BRU -> HAM with flight SN5501 departing at 2022-08-25 09:15:00 and arriving at 2022-08-25 10:30:00
--     HAM -> MEL with flight SN7502 departing at 2022-08-25 11:30:00
--     There is 1 hour between them and they are less than 20 hours apart, so BRU -> HAM -> MEL is a valid flight sequence.
--   * 1) HAM -> JNB with flight SN1511 departing at 2022-08-23 10:00:00 has as closest flight for BRU -> HAM SN1500 departing on 2022-08-20 09:00:00,
--        but this is more than 20 hours apart so it is not a valid flight sequence.
--     2) HAM -> JNB with flight SN3000 departing at 2023-03-05 10:00:00 has as only BRU -> HAM flight in that year SN1051 departing on 2023-03-05 08:30:00,
--        but this flight arrives at 2023-03-05 09:30:00 in HAM which means we only have 30 minutes. 
--        This would break the minimum connection time constraint, so this is not a valid flight sequence.
--   Valid flights with layovers should be:
--   * BRU -> HAM -> JFK: intercontinental, destination is in USA (North-America)
--   * BRU -> HAM -> MEL: intercontinental, destination is in Australia (Oceania)
*/

-- For clarity and readability, results will be obtained as the union of 2 queries.
-- The first query searches for all direct flights and the second query searches for flights with one layover.
-- direct flights
SELECT 
	-- formatted textual representation of the flight
	DISTINCT(CONCAT(f.departure_airport_iata, ' -> ', f.arrival_airport_iata)) as flight,
	-- a flight is continental if it has origin and destination airport in the same continent, 
	-- otherwise it is intercontinental
	CASE
		WHEN origin_addr.continent = destination_addr.continent
		THEN 'continental'
		ELSE 'intercontinental'
	END AS flight_type,
	-- this query will find direct flights
	false AS has_layovers
FROM flight AS f
-- get the departure airport's address to get access to the continent
JOIN airport AS origin_ap ON origin_ap.iata_code = f.departure_airport_iata
JOIN address AS origin_addr 
	ON origin_addr.street = origin_ap.address_street 
		AND origin_addr.postal_code = origin_ap.address_postal_code
		AND origin_addr.country = origin_ap.address_country
-- get the arrival airport's address to get access to the continent
JOIN airport AS destination_ap ON destination_ap.iata_code = f.arrival_airport_iata
JOIN address AS destination_addr 
	ON destination_addr.street = destination_ap.address_street 
		AND destination_addr.postal_code = destination_ap.address_postal_code
		AND destination_addr.country = destination_ap.address_country
-- only consider flights leaving from BRU
WHERE f.departure_airport_iata = 'BRU'

UNION

-- flights with layovers
SELECT
	-- formatted textual representation of the flight sequence
	DISTINCT(CONCAT(f1.departure_airport_iata, ' -> ', f1.arrival_airport_iata, ' -> ', f2.arrival_airport_iata)) as flight,
	-- a flight is considered to be continental if its final origin and destination airport are in the same continent
	-- (independent of whether the intermediate airport is in another continent for simplicity sake), 
	-- otherwise it is intercontinental
	CASE
		WHEN origin_addr.continent = destination_addr.continent
		THEN 'continental'
		ELSE 'intercontinental'
	END AS flight_type,
	-- this query will find flights with layovers
	true AS has_layovers
-- f1 is the flight to the layover destination
FROM flight AS f1
-- f2 is the flight from the layover stop to the final destination
JOIN flight AS f2 
	ON f2.departure_airport_iata = f1.arrival_airport_iata
		-- round-trip flights are excluded as that stop is not considered a layover
		AND f2.arrival_airport_iata <> f1.departure_airport_iata
		-- the layover flight should depart after the initial flight arrives
		AND f2.departure_date_time > f1.arrival_date_time
-- get the initial departure airport's address to get access to the continent
JOIN airport AS origin_ap ON origin_ap.iata_code = f1.departure_airport_iata
JOIN address AS origin_addr 
	ON origin_addr.street = origin_ap.address_street 
		AND origin_addr.postal_code = origin_ap.address_postal_code
		AND origin_addr.country = origin_ap.address_country
-- get the layover airport's minimum connection time to ensure both flights can be connected safely
JOIN airport AS intermediate_ap 
	ON intermediate_ap.iata_code = f1.arrival_airport_iata 
		AND intermediate_ap.iata_code = f2.departure_airport_iata
		AND intermediate_ap.mct < EXTRACT(epoch FROM f2.departure_date_time - f1.arrival_date_time)/60
-- get the final arrival airport's address to get access to the continent
JOIN airport AS destination_ap ON destination_ap.iata_code = f2.arrival_airport_iata
JOIN address AS destination_addr 
	ON destination_addr.street = destination_ap.address_street 
		AND destination_addr.postal_code = destination_ap.address_postal_code
		AND destination_addr.country = destination_ap.address_country
-- only consider flight sequences that start from BRU
WHERE f1.departure_airport_iata = 'BRU'
	-- for two flights to be considered as a possible connection in 1 larger encompassing flight,
	-- a limit of maximally 20 hours between them has been specified (which was an arbitrary choice by us)
	AND (EXTRACT(epoch FROM f2.departure_date_time - f1.arrival_date_time)/3600) < 20

ORDER BY flight_type, flight ;