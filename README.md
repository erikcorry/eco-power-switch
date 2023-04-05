# Eco Power Swich

Program to switch a power outlet on and off based on the current
price of electricity in Denmark.  This is also a good proxy for
the greenness of the electricity, as the price is largely determined
by the amount of wind and solar power available.

Runs on an ESP32-based smart plug, which is unfortunately not
currently available for sale.

The smart plug has a button.  Pressing the button moves between
the three modes.  After a power cut it starts in the AUTO mode,
