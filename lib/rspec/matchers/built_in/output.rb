require 'stringio'

module RSpec
  module Matchers
    module BuiltIn
      # @api private
      # Provides the implementation for `output`.
      # Not intended to be instantiated directly.
      class Output < BaseMatcher
        def initialize(expected)
          @expected        = expected
          @actual          = ""
          @block           = nil
          @stream_capturer = NullCapture
        end

        def matches?(block)
          @block = block
          return false unless Proc === block
          @actual = @stream_capturer.capture(block)
          @expected ? values_match?(@expected, @actual) : captured?
        end

        def does_not_match?(block)
          !matches?(block) && Proc === block
        end

        # @api public
        # Tells the matcher to match against stdout.
        # Works only when the main Ruby process prints to stdout
        def to_stdout
          @stream_capturer = CaptureStdout.new
          self
        end

        # @api public
        # Tells the matcher to match against stderr.
        # Works only when the main Ruby process prints to stderr
        def to_stderr
          @stream_capturer = CaptureStderr.new
          self
        end

        # @api public
        # Tells the matcher to match against stdout.
        # Works when subprocesses print to stdout as well.
        # This is significantly (~30x) slower than `to_stdout`
        def to_stdout_from_any_process
          @stream_capturer = CaptureStreamToTempfile.new("stdout", $stdout)
          self
        end

        # @api public
        # Tells the matcher to match against stderr.
        # Works when subprocesses print to stderr as well.
        # This is significantly (~30x) slower than `to_stderr`
        def to_stderr_from_any_process
          @stream_capturer = CaptureStreamToTempfile.new("stderr", $stderr)
          self
        end

        # @api public
        # Tells the matcher to simulate the output stream being a TTY.
        # This is useful to test code like `puts '...' if $stdout.tty?`.
        def as_tty
          raise ArgumentError, '`as_tty` can only be used after `to_stdout` or `to_stderr`' unless @stream_capturer.respond_to?(:as_tty=)

          @stream_capturer.as_tty = true
          self
        end

        # @api public
        # Tells the matcher to simulate the output stream not being a TTY.
        # Note that that's the default behaviour if you don't call `as_tty`
        # (since `StringIO` is not a TTY).
        def as_not_tty
          raise ArgumentError, '`as_not_tty` can only be used after `to_stdout` or `to_stderr`' unless @stream_capturer.respond_to?(:as_tty=)

          @stream_capturer.as_tty = false
          self
        end

        # @api private
        # @return [String]
        def failure_message
          "expected block to #{description}, but #{positive_failure_reason}"
        end

        # @api private
        # @return [String]
        def failure_message_when_negated
          "expected block to not #{description}, but #{negative_failure_reason}"
        end

        # @api private
        # @return [String]
        def description
          if @expected
            "output #{description_of @expected} to #{@stream_capturer.name}"
          else
            "output to #{@stream_capturer.name}"
          end
        end

        # @api private
        # @return [Boolean]
        def diffable?
          true
        end

        # @api private
        # Indicates this matcher matches against a block.
        # @return [True]
        def supports_block_expectations?
          true
        end

        # @api private
        # Indicates this matcher matches against a block only.
        # @return [False]
        def supports_value_expectations?
          false
        end

      private

        def captured?
          @actual.length > 0
        end

        def positive_failure_reason
          return "was not a block" unless Proc === @block
          return "output #{actual_output_description}" if @expected
          "did not"
        end

        def negative_failure_reason
          return "was not a block" unless Proc === @block
          "output #{actual_output_description}"
        end

        def actual_output_description
          return "nothing" unless captured?
          actual_formatted
        end
      end

      # @private
      module NullCapture
        def self.name
          "some stream"
        end

        def self.capture(_block)
          raise "You must chain `to_stdout` or `to_stderr` off of the `output(...)` matcher."
        end
      end

      # @private
      class CapturedStream < StringIO
        attr_accessor :as_tty

        def tty?
          return super if as_tty.nil?
          as_tty
        end
      end

      # @private
      class CaptureStdout
        attr_accessor :as_tty

        def name
          'stdout'
        end

        def capture(block)
          captured_stream = CapturedStream.new
          captured_stream.as_tty = as_tty

          original_stream = $stdout
          $stdout = captured_stream

          block.call

          captured_stream.string
        ensure
          $stdout = original_stream
          $stdout.write(captured_stream.string) unless $stdout == STDOUT # rubocop:disable Style/GlobalStdStream
        end
      end

      # @private
      class CaptureStderr
        attr_accessor :as_tty

        def name
          'stderr'
        end

        def capture(block)
          captured_stream = CapturedStream.new
          captured_stream.as_tty = as_tty

          original_stream = $stderr
          $stderr = captured_stream

          block.call

          captured_stream.string
        ensure
          $stderr = original_stream
          $stderr.write(captured_stream.string) unless $stderr == STDERR # rubocop:disable Style/GlobalStdStream
        end
      end

      # @private
      class CaptureStreamToTempfile < Struct.new(:name, :stream)
        def capture(block)
          # We delay loading tempfile until it is actually needed because
          # we want to minimize stdlibs loaded so that users who use a
          # portion of the stdlib can't have passing specs while forgetting
          # to load it themselves. `CaptureStreamToTempfile` is rarely used
          # and `tempfile` pulls in a bunch of things (delegate, tmpdir,
          # thread, fileutils, etc), so it's worth delaying it until this point.
          require 'tempfile'

          # This is.. awkward-looking. But it's written this way because of how
          # compound matchers work - we essentially need to be able to tell if
          # we're in an _inner_ matcher, so we can pass the stream-output along
          # to the outer matcher for further evaluation in that case. Added to
          # that, it's fairly difficult to _tell_, because the only actual state
          # we have access to is the stream itself, and in the case of stderr,
          # that stream is really a RSpec::Support::StdErrSplitter (which is why
          # we're testing `is_a?(File)` in such an obnoxious way).
          inner_matcher = stream.to_io.is_a?(File)

          # Careful here - the StdErrSplitter is what is being cloned; we're
          # relying on the implemented clone method of that class (in
          # rspec-support) to actually clone the File for ensure-reopen.
          original_stream = stream.clone

          captured_stream = Tempfile.new(name)

          begin
            captured_stream.sync = true
            stream.reopen(captured_stream)
            block.call
            read_contents(captured_stream)
          ensure
            captured_content = inner_matcher ? read_contents(captured_stream) : nil
            stream.reopen(original_stream)
            stream.write(captured_content) if captured_content
            clean_up_tempfile(captured_stream)
          end
        end

        private

        def read_contents(captured_stream)
          captured_stream.rewind
          captured_stream.read
        end

        def clean_up_tempfile(tempfile)
          tempfile.close
          tempfile.unlink
        end
      end
    end
  end
end
