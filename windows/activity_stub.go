//go:build !windows

package main

// Non-Windows builds have no tray console; activity lines just go to the log.
func activityLog(string)      {}
func showActivity()           {}
func hideActivity()           {}
func activityVisible() bool   { return false }
