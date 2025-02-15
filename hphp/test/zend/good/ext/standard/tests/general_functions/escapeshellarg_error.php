<?hh
/* Prototype  : string escapeshellarg  ( string $arg  )
 * Description:  Escape a string to be used as a shell argument.
 * Source code: ext/standard/exec.c
 */
/*
 * Pass an incorrect number of arguments to escapeshellarg() to test behaviour
 */
class classA {}

<<__EntryPoint>> function main(): void {

echo "*** Testing escapeshellarg() : error conditions ***\n";

echo "\n-- Testing escapeshellarg() function with no arguments --\n";
try { var_dump( escapeshellarg() ); } catch (Exception $e) { echo "\n".'Warning: '.$e->getMessage().' in '.__FILE__.' on line '.__LINE__."\n"; }

echo "\n-- Testing escapeshellarg() function with more than expected no. of arguments --\n";
$arg = "Mr O'Neil";
$extra_arg = 10;
try { var_dump( escapeshellarg($arg, $extra_arg) ); } catch (Exception $e) { echo "\n".'Warning: '.$e->getMessage().' in '.__FILE__.' on line '.__LINE__."\n"; }

echo "===Done===";
}
