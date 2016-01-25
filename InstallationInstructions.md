js2-mode instructions

# Introduction #

`js2-mode` is a new JavaScript editing mode for GNU Emacs.  It aims to be more like an IDE (such as Eclipse or IntelliJ) than existing Emacs language modes.  There is a lot of work left to do to achieve this goal, but it's got a pretty good start:

  * it offers the usual features from other Emacs modes
  * it supports the JavaScript language up through version 1.7
  * it has a real recursive-descent parser
  * it highlights syntax errors and underlines warnings
  * it supports collapsing function-body and block-comment definitions
  * it has some preliminary support for IMenu (to be improved soon)
  * it knows about jsdoc and highlights tags in jsdoc comments
  * it has a set of typing helpers to make editing easier

Most of the mode's features are customizable via M-x customize.

# Details #

To install `js2-mode`:

  * download the latest source distribution file, `js2-XXXXXXXX.el`
  * put it in your Emacs load-path somewhere as `js2.el`
  * in Emacs, `M-x byte-compile-file RE js2.el RET`
  * add these lines to your .emacs file:

```
(autoload 'js2-mode "js2" nil t)
(add-to-list 'auto-mode-alist '("\\.js$" . js2-mode))
```

It will refuse to run unless you have byte-compiled it.
You must byte-compile it with your version of Emacs because
different versions of Emacs have different byte-compiled formats.

# Usage Notes #

Invoke `M-x customize-group RET js2-mode RET` to see the configuration options.

This mode does not have customizable indentation the way cc-engine modes do (e.g. java-mode, c-mode, objc-mode).  It is a significant amount of work to create a customizable indenter.

Instead, `js2-mode` uses an indentation guesser (based on Karl LandstrÃ¶m's "javascript.el" guesser), plus "bounce-indenting".  When you hit TAB the first time to indent a line, it indents to what it thinks is the most likely indentation point, and it computes a set of other possibilities.  If you hit TAB repeatedly, it cycles among these possibilities.

There are obvious downsides to this approach, but hopefully over time the indentation support will improve.

# Installing from source code #

As an alternate way to install the mode, you can download the source files from the svn repository (from the Source tab above), put them in your load-path, and byte-compile each of them.  The mode runs without being byte-compiled in "developer mode" (i.e. from source), so be careful, since it's really really slow for large files.

If you're using the svn sources, you can get the latest updates between official releases.