// Copyright (C) 2023 Erik Corry.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import certificate_roots
import encoding.json
import gpio
import gpio.pwm
import http
import ntp
import net

// Program to switch a power outlet on and off based on the current
// price of electricity in Denmark.  This is also a good proxy for
// the greenness of the electricity, as the price is largely determined
// by the amount of wind and solar power available.

// Runs on an ESP32-based smart plug, which is unfortunately not
// currently available for sale.

// The smart plug has a button.  Pressing the button moves between
// the three modes.  After a power cut it starts in the AUTO mode,

AUTO ::= 0
ON ::= 1
OFF ::= 2

MAX_PRICE ::= 0.61  // Maximum price to pay for power is 1.0 per kWh, but we pay 0.39 in taxes and transport.
// API for current price (without VAT):
HOST      ::= "www.elprisenligenu.dk"
CURRENCY  ::= "DKK"
// Get with: tail -n1 /usr/share/zoneinfo/Europe/Copenhagen 
TIME_ZONE ::= "CET-1CEST,M3.5.0,M10.5.0/3"  // Time zone with daylight savings switching.
GEOGRAPHY ::= "DK1"  // DK1 is West of Storebælt, DK2 is East of Storebælt.
CERT_ROOT ::= certificate_roots.ISRG_ROOT_X1
POWER_PIN ::= 2   // Power is controlled by GPIO pin 2.
RED_PIN   ::= 23  // Red part of LED is connected to GPIO pin 23.
GREEN_PIN ::= 22  // Green part of LED is connected to GPIO pin 22.
BLUE_PIN  ::= 21  // Blue part of LED is connected to GPIO pin 21.
POWER_ON  ::= 1   // Power is on when GPIO pin is high.
POWER_OFF ::= 0   // Power is off when GPIO pin is low.

// Immutable situation object.
situation /Situation := Situation

main:
  set_timezone TIME_ZONE
  power/gpio.Pin? := null
  button/gpio.Pin? := null
  catch:
    // If we can't get the GPIO pin, we ignore that because we are probably
    // just testing on a desktop.
    power = gpio.Pin.out POWER_PIN
    button = gpio.Pin.in 0
  led := Led
  task:: monitor_button button
  task:: control power led
  task:: fetch_prices

// Task that updates the price of electricity from an API.
// Places the result in the situation variable.
fetch_prices:
  interface := net.open
  client := http.Client.tls interface
      --root_certificates=[CERT_ROOT]
  today/string? := null
  json_result/List? := null

  while true:
    // Big catch for all intermittent network errors.
    catch --trace:
      now := get_now
      // The API lets you fetch one day, using the local time zone
      // to determine when the day starts and ends.
      local := now.local
      new_today := "$local.year/$(%02d local.month)-$(%02d local.day)"
      // They don't normally update the hourly prices after the day
      // started, so if we already have the prices for today, we
      // don't need to fetch them again.
      if new_today != today or not json_result:
        path := "/api/v1/prices/$(new_today)_$(GEOGRAPHY).json"
        print "Fetching $path"
        response := client.get --host=HOST --path=path
        if response.status_code == 200:
          json_result = json.decode_stream response.body
        else:
          print "Response status code: $response.status_code"
          clear_ntp_adjustment
      if json_result:
        // The JSON is just an array of hourly prices.
        json_result.do: | period |
          start := Time.from_string period["time_start"]
          end := Time.from_string period["time_end"]
          if start <= now < end:
            price := period["$(CURRENCY)_per_kWh"]
            situation = situation.update_price price
            print "Electricity $(price_format price) $CURRENCY/kWh"
            // Successful fetch, so we can set the variable and not fetch again.
            today = new_today
    // Random sleep to avoid hammering the server if it is down, or just after
    // midnight when we need to fetch a new day. This also avoids hammering the
    // grid with a huge power spike at the top of each hour (when there are
    // millions using this program!).
    ms := (random 100_000) + 100_000
    print "Sleep for $(ms / 1000) seconds"
    sleep --ms=ms

// Task that updates the LEDs and power based on the current situation.
control power/gpio.Pin? led/Led:
  old_situation := null
  while true:
    sleep --ms=20
    if situation != old_situation:
      old_situation = situation
      state := situation.state
      price := situation.price
      if state == ON:
        if power: power.set POWER_ON
        led.set 0.0 0.5 1.0 // Turquoise: Manual on.
        print "Turquoise"
      else if state == OFF:
        if power: power.set POWER_OFF
        led.set 1.0 0.0 1.0 // Purple: Manual off.
        print "Purple"
      else if price:
        if price <= MAX_PRICE:
          if power: power.set POWER_ON
          led.set 0.0 0.5 0.0 // Green: Auto on.
          print "Green"
        else:
          if power: power.set POWER_OFF
          if price <= MAX_PRICE * 2:
            led.set 1.0 0.2 0.0 // Orange: Auto off - medium price.
            print "Orange"
          else:
            led.set 1.0 0.0 0.0 // Red: Auto off - expensive.
            print "Red"
      else:
        led.set 0.0 0.0 0.0 // Black: No price, no manual override.
        print "Black"

// Task that keeps an eye on the button, to switch between manual and automatic
// modes.
monitor_button button/gpio.Pin?:
  if not button: return
  while true:
    while button.get == 1:
      // Button not pressed.
      sleep --ms=10
    situation = situation.next_state
    while button.get == 0:
      // Button pressed.
      sleep --ms=10

ntp_counter/int := 0
ntp_result := null

get_now -> Time:
  // One time in 100 we bother the server for a new NTP adjustment.  Small
  // devices might not have any other process fetching the NTP time.
  if not ntp_result or ntp_counter % 100 == 0:
    ntp_result = ntp.synchronize
    print "Getting NTP adjustment $ntp_result.adjustment"
  ntp_counter++
  return Time.now + ntp_result.adjustment

clear_ntp_adjustment -> none:
  // Fetching the prices might have failed because our clock is wrong.  Let's
  // try to get a new NTP adjustment next time.
  ntp_result = null

price_format price/num -> string:
  int_part := price.to_int
  frac_part := ((price - int_part) * 100).round
  if frac_part == 100:
    int_part++
    frac_part = 0
  return "$(int_part).$(%02d frac_part)"

class Situation:
  price/float? ::= null
  state/int ::= AUTO

  constructor:

  constructor.private_ .price .state:

  operator == other/Situation:
    return price == other.price and state == other.state

  update_price price/float -> Situation:
    return Situation.private_ price state

  next_state -> Situation:
    new_state := (state + 1) % 3
    return Situation.private_ price new_state

class Led:
  red_channel /pwm.PwmChannel? := null
  green_channel /pwm.PwmChannel? := null
  blue_channel /pwm.PwmChannel? := null

  constructor:
    catch:
      // If we can't get the GPIO pins, we ignore that because we are probably
      // just testing on a desktop.
      red   := gpio.Pin.out RED_PIN
      green := gpio.Pin.out GREEN_PIN
      blue  := gpio.Pin.out BLUE_PIN
      generator := pwm.Pwm --frequency=400
      red_channel = generator.start red
      green_channel = generator.start green
      blue_channel = generator.start blue

  set r/float g/float b/float:
    if red_channel: red_channel.set_duty_factor r
    if green_channel: green_channel.set_duty_factor g
    if blue_channel: blue_channel.set_duty_factor b
    print "Set LED to #$(%02x (r * 255).to_int)$(%02x (g * 255).to_int)$(%02x (b * 255).to_int)"
