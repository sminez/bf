# == Embrace the Blobfish ==
```
       ,-,
      ('_)<
       `-`

usage:
  bf [c]apture <file>  quickly capture an idea for later reviewing
  bf [n]ote <file>     open/create a note file
  bf [f]ind            search tagged notes and helpfiles
  bf [g]rep <pattern>  search note content using rg
  bf [t]odo            open the top level TODO file

  bf [s]ync            force sync with the remote repo
  bf [h]elp            display this help message
```

> A blobfish out of its depth is a sad sight, don't blame it for how it looks.
> It's just out of its depth!

This is my current iteration on a simple CLI tool for managing my personal
notes and TODO list. It makes a lot of assumptions about how you are tracking things
so it likely isn't for you, but you may find it interesting.

--------------------

## == Disclaimer ==
This is a helper script that aims to acts as a capture and review system to
help me keep on top of things, regardless of what those things are. There
are several directories that are required/expected to exist and in order to
keep things simple `bf` will simply fail loudly if it finds itself unable to
proceed.

>> In short, this is me-ware: not really us-ware and DEFINITELY not them-ware!


### Helpfiles

The helpfile format available with `find` is from my [k](https://github.com/sminez/k) script.
It's a super simple markup format for managing small notes and snippets so that they are easy
to search through when you've spaced on just exactly what it was you were after.
