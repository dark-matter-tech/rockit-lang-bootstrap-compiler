# Language Reference

This is a summary of the Rockit language as implemented by the bootstrap compiler. For the full specification, see the Rockit language spec.

## Basics

### Variables

```rockit
val name: String = "Rockit"     // Immutable (like Kotlin val)
var count: Int = 0              // Mutable
val inferred = 42               // Type inferred as Int
```

### Types

| Type | Description | Example |
|------|-------------|---------|
| `Int` | 64-bit integer | `42`, `0xFF`, `0b1010`, `1_000` |
| `Float` | 64-bit float | `3.14`, `1.0e10` |
| `Bool` | Boolean | `true`, `false` |
| `String` | UTF-8 string | `"hello"`, `"age: ${age}"` |
| `Char` | Single character | `'a'` |
| `Unit` | No value (void) | — |
| `Nothing` | Never returns | — |
| `Any` | Top type | — |

### Null Safety

```rockit
val s: String = "hello"         // Non-null, guaranteed
val s: String? = null           // Nullable

s?.length                        // Safe call (returns null if s is null)
s ?: "default"                   // Elvis operator (default if null)
s!!                              // Non-null assertion (throws if null)
```

## Functions

```rockit
fun greet(name: String): String {
    return "Hello, $name!"
}

// Expression body
fun double(x: Int): Int = x * 2

// Default parameters
fun connect(host: String, port: Int = 8080): Unit { ... }

// Named arguments
connect(port = 443, host = "example.com")

// Varargs
fun sum(vararg numbers: Int): Int { ... }

// Suspend functions (coroutines)
suspend fun fetchData(url: String): String { ... }
```

## Classes

```rockit
// Regular class
class Person(val name: String, var age: Int) {
    fun greet(): String = "Hi, I'm $name"
}

// Data class (auto-generates equals, hashCode, toString, copy)
data class Point(val x: Int, val y: Int)

// Sealed class (restricted hierarchy)
sealed class Shape {
    class Circle(val radius: Float) : Shape()
    class Rectangle(val w: Float, val h: Float) : Shape()
}

// Inheritance
class Student(name: String, val grade: Int) : Person(name, 18) {
    override fun greet(): String = "Student $name, grade $grade"
}
```

## Enums

```rockit
enum class Color {
    Red, Green, Blue
}

enum class Direction {
    North, South, East, West;

    fun opposite(): Direction = when (this) {
        Direction.North -> Direction.South
        Direction.South -> Direction.North
        Direction.East -> Direction.West
        Direction.West -> Direction.East
    }
}
```

## Interfaces

```rockit
interface Drawable {
    fun draw(): Unit

    // Default method implementation
    fun describe(): String = "A drawable object"
}

class Circle(val r: Float) : Drawable {
    override fun draw(): Unit { ... }
}
```

## Control Flow

### If Expression

```rockit
// Statement
if (x > 0) {
    println("positive")
} else if (x < 0) {
    println("negative")
} else {
    println("zero")
}

// Expression (returns a value)
val sign = if (x > 0) "+" else "-"
```

### When Expression

```rockit
// Value matching
when (x) {
    1 -> println("one")
    2, 3 -> println("two or three")
    in 4..10 -> println("four to ten")
    else -> println("other")
}

// Type matching
when (shape) {
    is Circle -> println("radius: ${shape.radius}")
    is Rectangle -> println("${shape.w} x ${shape.h}")
}

// Exhaustive (sealed classes/enums — no else needed)
val area: Float = when (shape) {
    is Circle -> 3.14 * shape.radius * shape.radius
    is Rectangle -> shape.w * shape.h
}
```

### Loops

```rockit
// For loop
for (i in 0..9) { println(i) }
for (item in list) { println(item) }

// While
while (condition) { ... }

// Do-while
do { ... } while (condition)
```

## Lambdas and Closures

```rockit
val double = { x: Int -> x * 2 }
val result = double(21)  // 42

// Trailing lambda syntax
list.filter { it > 0 }
list.map { it.toString() }

// Multi-line lambda
list.fold(0) { acc, item ->
    acc + item
}
```

## String Interpolation

```rockit
val name = "World"
println("Hello, $name!")              // Simple reference
println("1 + 1 = ${1 + 1}")          // Expression
println("Name length: ${name.length}") // Member access
```

## Generics

```rockit
class Box<T>(val value: T)

fun <T> identity(x: T): T = x

// Variance
interface Producer<out T> {    // Covariant (can return T)
    fun produce(): T
}

interface Consumer<in T> {     // Contravariant (can accept T)
    fun consume(item: T): Unit
}
```

## Concurrency

### Suspend Functions

```rockit
suspend fun fetchUser(id: Int): User {
    val response = await httpGet("/users/$id")
    return parseUser(response)
}
```

### Concurrent Blocks

```rockit
concurrent {
    val user = async { fetchUser(1) }
    val posts = async { fetchPosts(1) }
    // Both run concurrently, joined at block end
}
```

### Actors

```rockit
actor Counter {
    var count: Int = 0

    fun increment(): Unit {
        count = count + 1
    }

    fun getCount(): Int = count
}

// Actor methods are dispatched via mailbox (thread-safe)
val counter = Counter()
counter.increment()  // Message send, not direct call
```

## Views (UI)

```rockit
view Greeting(name: String) {
    Text("Hello, $name!")
    Button("Click me") {
        println("clicked")
    }
}
```

## Memory Management

```rockit
// ARC (Automatic Reference Counting)
val obj = MyClass()     // refCount = 1
val ref = obj           // refCount = 2
// ref goes out of scope → refCount = 1
// obj goes out of scope → refCount = 0 → deallocated

// Weak references (break retain cycles)
weak var delegate: Delegate? = null

// Unowned references (non-null, no retain)
unowned var parent: Node = rootNode
```

## Freestanding Mode

For systems programming without the standard runtime:

```rockit
// Pointer types
val ptr: Ptr<Int> = alloc(8)
storeByte(ptr, 0, 42)
val value = loadByte(ptr, 0)
free(ptr)

// Unsafe blocks
unsafe {
    val raw = bitcast<Ptr<Byte>>(ptr)
}

// C interop
extern fun printf(format: Ptr<Byte>, vararg args: Any): Int

// C-compatible struct layout
@CRepr
class MyStruct {
    var x: Int = 0
    var y: Int = 0
}
```

## Grammar (EBNF Summary)

```ebnf
program       = { declaration } ;
declaration   = funDecl | viewDecl | classDecl | enumDecl
              | interfaceDecl | actorDecl | typeAlias ;

funDecl       = ["suspend"] "fun" id [typeParams]
                "(" [params] ")" [":" type] block ;
viewDecl      = "view" id "(" [params] ")" viewBlock ;
classDecl     = ["data"|"sealed"] "class" id [typeParams]
                ["(" [params] ")"] [":" typeList] classBlock ;
actorDecl     = "actor" id classBlock ;
enumDecl      = "enum" "class" id enumBlock ;

type          = id [typeArgs] ["?"] | funcType | tupleType ;
funcType      = "(" [typeList] ")" "->" type ;

statement     = valDecl | varDecl | assignment | expression
              | ifExpr | whenExpr | forLoop | returnStmt ;
valDecl       = "val" id [":" type] "=" expression ;
varDecl       = ["weak"|"unowned"] "var" id [":" type] "=" expr ;
whenExpr      = "when" "(" expr ")" "{" { whenEntry } "}" ;
lambda        = "{" [params "->"] statements "}" ;
```
