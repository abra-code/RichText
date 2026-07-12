A backtick fence with a language:

```swift
let x = 42  // a comment
let s = "hello"
```

A tilde fence with no language:

~~~
plain text
no highlighting
~~~

A fence whose body contains a shorter run stays open:

````
inside ``` still code
````

Markup inside a fence is not parsed:

```
**not bold** and [not a link](http://x.test)
```

An unterminated fence swallows the rest:

```python
def f():
    return 1
