#  Phusion Passenger - http://www.modrails.com/
#  Copyright (C) 2008  Phusion
#
#  Phusion Passenger is a trademark of Hongli Lai & Ninh Bui.
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

require 'rubygems'
require 'thread'
if RUBY_PLATFORM != "java" && (RUBY_VERSION < "1.8.6" || (RUBY_VERSION == "1.8.6" && RUBY_PATCHLEVEL < 110))
	require 'fastthread'
end
require 'pathname'
require 'etc'
require 'passenger/exceptions'
if RUBY_PLATFORM != "java"
	require 'passenger/native_support'
end

module Passenger

# Utility functions.
module Utils
protected
	# Return the absolute version of +path+. This path is guaranteed to
	# to be "normal", i.e. it doesn't contain stuff like ".." or "/",
	# and it correctly respects symbolic links.
	#
	# Raises SystemCallError if something went wrong. Raises ArgumentError
	# if +path+ is nil.
	def normalize_path(path)
		raise ArgumentError, "The 'path' argument may not be nil" if path.nil?
		return Pathname.new(path).realpath.to_s
	rescue Errno::ENOENT => e
		raise ArgumentError, e.message
	end
	
	# Assert that +app_root+ is a valid Ruby on Rails application root.
	# Raises ArgumentError if that is not the case.
	def assert_valid_app_root(app_root)
		assert_valid_directory(app_root)
		assert_valid_file("#{app_root}/config/environment.rb")
	end
	
	# Assert that +path+ is a directory. Raises +ArgumentError+ if it isn't.
	def assert_valid_directory(path)
		if !File.directory?(path)
			raise ArgumentError, "'#{path}' is not a valid directory."
		end
	end
	
	# Assert that +path+ is a file. Raises +ArgumentError+ if it isn't.
	def assert_valid_file(path)
		if !File.file?(path)
			raise ArgumentError, "'#{path}' is not a valid file."
		end
	end
	
	# Assert that +username+ is a valid username. Raises
	# ArgumentError if that is not the case.
	def assert_valid_username(username)
		# If username does not exist then getpwnam() will raise an ArgumentError.
		username && Etc.getpwnam(username)
	end
	
	# Assert that +groupname+ is a valid group name. Raises
	# ArgumentError if that is not the case.
	def assert_valid_groupname(groupname)
		# If groupname does not exist then getgrnam() will raise an ArgumentError.
		groupname && Etc.getgrnam(groupname)
	end
	
	def marshal_exception(exception)
		data = {
			:message => exception.message,
			:class => exception.class.to_s,
			:backtrace => exception.backtrace
		}
		if exception.is_a?(InitializationError)
			data[:is_initialization_error] = true
			if exception.child_exception
				data[:child_exception] = marshal_exception(exception.child_exception)
			end
		else
			begin
				data[:exception] = Marshal.dump(exception)
			rescue ArgumentError, TypeError
				e = UnknownError.new(exception.message, exception.class.to_s,
							exception.backtrace)
				data[:exception] = Marshal.dump(e)
			end
		end
		return Marshal.dump(data)
	end
	
	def unmarshal_exception(data)
		hash = Marshal.load(data)
		if hash[:is_initialization_error]
			if hash[:child_exception]
				child_exception = unmarshal_exception(hash[:child_exception])
			else
				child_exception = nil
			end
			
			case hash[:class]
			when AppInitError.to_s
				exception_class = AppInitError
			when FrameworkInitError.to_s
				exception_class = FrameworkInitError
			else
				exception_class = InitializationError
			end
			return exception_class.new(hash[:message], child_exception)
		else
			begin
				return Marshal.load(hash[:exception])
			rescue ArgumentError, TypeError
				return UnknownError.new(hash[:message], hash[:class], hash[:backtrace])
			end
		end
	end
	
	# Print the given exception, including the stack trace, to STDERR.
	#
	# +current_location+ is a string which describes where the code is
	# currently at. Usually the current class name will be enough.
	def print_exception(current_location, exception)
		if !exception.is_a?(SystemExit)
			STDERR.puts(exception.backtrace_string(current_location))
			STDERR.flush
		end
	end
	
	# Fork a new process and run the given block inside the child process, just like
	# fork(). Unlike fork(), this method is safe, i.e. there's no way for the child
	# process to escape the block. Any uncaught exceptions in the child process will
	# be printed to standard output, citing _current_location_ as the source.
	def safe_fork(current_location)
		return fork do
			begin
				yield
			rescue Exception => e
				print_exception(current_location, e)
			ensure
				exit!
			end
		end
	end
end

end # module Passenger

class Exception
	def backtrace_string(current_location = nil)
		if current_location.nil?
			location = nil
		else
			location = "in #{current_location} "
		end
		return "*** Exception #{self.class} #{location}" <<
			"(#{self}) (process #{$$}):\n" <<
			"\tfrom " << backtrace.join("\n\tfrom ")
	end
end

class ConditionVariable
	# This is like ConditionVariable.wait(), but allows one to wait a maximum
	# amount of time. Returns true if this condition was signaled, false if a
	# timeout occurred.
	def timed_wait(mutex, secs)
		require 'timeout' unless defined?(Timeout)
		if secs > 0
			Timeout.timeout(secs) do
				wait(mutex)
			end
		else
			wait(mutex)
		end
		return true
	rescue Timeout::Error
		return false
	end
	
	# This is like ConditionVariable.wait(), but allows one to wait a maximum
	# amount of time. Raises Timeout::Error if the timeout has elapsed.
	def timed_wait!(mutex, secs)
		require 'timeout' unless defined?(Timeout)
		if secs > 0
			Timeout.timeout(secs) do
				wait(mutex)
			end
		else
			wait(mutex)
		end
	end
end

class IO
	# Send an IO object (i.e. a file descriptor) over this IO channel.
	# This only works if this IO channel is a Unix socket.
	#
	# Raises SystemCallError if something went wrong.
	def send_io(io)
		Passenger::NativeSupport.send_fd(self.fileno, io.fileno)
	end
	
	# Receive an IO object (i.e. a file descriptor) from this IO channel.
	# This only works if this IO channel is a Unix socket.
	#
	# Raises SystemCallError if something went wrong.
	def recv_io
		return IO.new(Passenger::NativeSupport.recv_fd(self.fileno))
	end
end

module GC
	if !respond_to?(:copy_on_write_friendly?)
		# Checks whether the current Ruby interpreter's garbage
		# collector is copy-on-write friendly.
		def self.copy_on_write_friendly?
			return false
		end
	end
end

