{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DuplicateRecordFields #-}
-- | Tools for running Terraform.
--
-- Copyright (c) 2018 Jonathan M. Lange
--
-- This file is part of terradiff.
--
-- terradiff is free software: you can redistribute it and/or modify it
-- under the terms of the GNU Affero General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or (at your
-- option) any later version.
--
-- terradiff is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
-- for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with terradiff. If not, see <https://www.gnu.org/licenses/>.
module Terradiff.Terraform
  ( FlagConfig(..)
  , flags
  , Config(..)
  , validateFlagConfig
  -- * Higher level Terraform operations.
  , ProcessResult(..)
  , Diff(..)
  , Error(..)
  , Terradiff.Terraform.diff
  ) where

import Protolude

import Control.Monad.Logger.CallStack
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.String (String)
import qualified Options.Applicative as Opt
import qualified Prometheus
import qualified System.Clock as Clock
import System.Environment (getEnvironment)
import System.Posix (getWorkingDirectory)
import qualified System.Process as Process
import Text.Show (Show(..))

-- | Configuration for running Terraform, as can be specified on the command line.
data FlagConfig
  = FlagConfig
  { -- | Where we can find the Terraform binary
    terraformBinary :: FilePath
    -- | Where to find the actual Terraform config files
  , flagTerraformPath :: Maybe FilePath
    -- | The terraform working directory. We will run 'terraform init' here.
  , workingDirectory :: Maybe FilePath
    -- | Optional Terraform log level. If unspecified, we let Terraform decide.
  , flagTerraformLogLevel :: Maybe String
    -- | Whether to enable Terraform state locking
  , flagTerraformLocking :: Bool
    -- | Files containing optional AWS credentials
  , awsCredentialsFiles :: Maybe AWSCredentialsFiles
    -- | File to load an optional GitHub token from
  , gitHubTokenFile :: Maybe FilePath
  } deriving (Eq, Show)

-- | Configure our Terraform usage from the command line.
flags :: Opt.Parser FlagConfig
flags =
  FlagConfig
  <$> Opt.option
        Opt.str
        (fold
         [ Opt.long "terraform-binary"
         , Opt.help "Path to terraform binary. If not provided, will assume 'terraform' on PATH."
         , Opt.value "terraform"
         ])
  <*> optional
       (Opt.option
        Opt.str
        (fold
         [ Opt.long "terraform-files"
         , Opt.help "Directory where the actual Terraform files live."
         ]))
  <*> optional
        (Opt.option
         Opt.str
         (fold
          [ Opt.long "terraform-working-directory"
          , Opt.help "Where we will run terraform."
          ]))
  <*> optional
        (Opt.option
         Opt.str
         (fold
          [ Opt.long "terraform-log-level"
          , Opt.help "Log level for Terraform itself. Useful for debugging errors. One of 'TRACE', 'DEBUG', 'INFO', 'WARN', or 'ERROR'."
          ]))
  <*> Opt.switch
        (fold
         [ Opt.long "terraform-locking"
         , Opt.help "Whether to use Terraform state locking"
         ])
  <*> optional awsCredentialsFlags
  <*> optional
        (Opt.option
         Opt.str
         (fold
          [ Opt.long "github-token-file"
          , Opt.help "Path to a file with a GitHub bearer token"
          ]))

-- | Configuration for running Terraform. Either construct this directly or
-- from a 'FlagConfig' using 'validateFlagConfig'.
data Config
  = Config
  { -- | Where we can find the Terraform binary
    terraformBinary :: FilePath
    -- | Where the Terraform config files live.
  , terraformPath :: FilePath
    -- | The terraform working directory. We will run 'terraform init' here.
  , workingDirectory :: FilePath
    -- | Optional Terraform log level. If unspecified, we let Terraform decide.
  , terraformLogLevel :: Maybe String
    -- | Whether to enable Terraform state locking
  , terraformLocking :: Bool
    -- | Optional AWS credentials
  , awsCredentials :: Maybe AWSCredentials
    -- | Optional GitHub credentials
  , gitHubToken :: Maybe GitHubToken
    -- | How long Terraform commands take to run.
  , commandDuration :: Prometheus.Metric (Prometheus.Vector (String, String) Prometheus.Histogram)
    -- | Result of latest 'terraform plan' command.
  , planExitCode :: Prometheus.Metric Prometheus.Gauge
  }

-- | Convert command-line configuration into something we can actually use.
-- XXX: This doesn't do any validation, so the function name is pretty terrible.
--
-- XXX: Should we use this opportunity to check that the working directory
-- exists and is a directory? Possibly helpful to the end user, but not
-- actually relevant for correct operation, as the directory can always be
-- deleted or turned into a file while we are running.
validateFlagConfig :: (HasCallStack, MonadIO io) => FlagConfig -> io Config
validateFlagConfig FlagConfig{terraformBinary, workingDirectory, flagTerraformPath, flagTerraformLogLevel, flagTerraformLocking, awsCredentialsFiles, gitHubTokenFile} = do
  awsCreds <- traverse awsCredentialsFromFiles awsCredentialsFiles
  gitHubToken <- traverse gitHubTokenFromFile gitHubTokenFile
  -- Working directory is the current directory if not specified
  workDir <- maybe (liftIO getWorkingDirectory) pure workingDirectory
  -- Path to configs is the working directory if not specified.
  let tfPath = fromMaybe workDir flagTerraformPath
  commandDuration <- liftIO $ Prometheus.registerIO commandDurationMetric
  planExitCode <- liftIO $ Prometheus.registerIO planExitCodeMetric
  pure $ Config terraformBinary tfPath workDir flagTerraformLogLevel flagTerraformLocking awsCreds gitHubToken commandDuration planExitCode

-- | Metric used to report on how long commands take to run.
commandDurationMetric :: HasCallStack => IO (Prometheus.Metric (Prometheus.Vector (String, String) Prometheus.Histogram))
commandDurationMetric =
  Prometheus.vector ("command" :: String, "exit_code" :: String)
  (Prometheus.histogram
    (Prometheus.Info
      "terradiff_terraform_command_duration_seconds"
      "How long Terraform commands take to run")
    (Prometheus.linearBuckets 0.0 2.0 12))  -- `terraform` generally takes a few seconds to run.

-- | Metric used to export the current state of the terraform diff.
planExitCodeMetric :: HasCallStack => IO (Prometheus.Metric Prometheus.Gauge)
planExitCodeMetric =
  Prometheus.gauge
  (Prometheus.Info
    "terradiff_plan_exit_code"
    "The exit code of the latest run of 'terraform plan'.")

-- | Run Terraform.
runTerraform :: (MonadLogger m, MonadIO m, HasCallStack) => Config -> ByteString -> [ByteString] -> m ProcessResult
runTerraform Config{terraformBinary, workingDirectory, terraformLogLevel, awsCredentials, gitHubToken, commandDuration} cmd args = do
  start <- liftIO $ Clock.getTime Clock.Monotonic
  initEnv <- liftIO getEnvironment
  let process = (Process.proc terraformBinary terraformArgs)
                { Process.env = Just (initEnv ++ env)
                , Process.cwd = Just workingDirectory
                }
  (exitCode, out, err) <- liftIO $ Process.readCreateProcessWithExitCode process ""
  end <- liftIO $ Clock.getTime Clock.Monotonic
  let duration = Clock.toNanoSecs (end `Clock.diffTimeSpec` start) % 1000000000
  liftIO $ Prometheus.withLabel (toS cmd, exitLabel exitCode) (Prometheus.observe (fromRational duration)) commandDuration
  let result = ProcessResult (toS cmd) process exitCode (toS out) (toS err)
  logDebug $ "Ran terraform process: " <> Protolude.show process <> " ; " <> Protolude.show result
  pure result
  where
    terraformArgs = map toS (cmd:args)
    -- See https://www.terraform.io/docs/configuration/environment-variables.html
    -- and https://www.terraform.io/guides/running-terraform-in-automation.html
    -- for more information.
    env = [ ("TF_IN_AUTOMATION", "1")  -- Subtly change the output to be more appropriate to automation
          , ("TF_INPUT", "0")  -- Do not prompt for user input
          , ("TF_CLI_ARGS", "-no-color")  -- Don't use color, for better HTML rendering
          , ("HOME", workingDirectory)  -- Terraform needs the home directory for variable expansion
          ] <> logLevel <> awsCreds <> gitHubCreds
    logLevel = maybe [] (\x -> [("TF_LOG", x)]) terraformLogLevel
    awsCreds = maybe [] awsCredentialsToEnvVars awsCredentials
    gitHubCreds = maybe [] gitHubTokenToEnvVars gitHubToken

    exitLabel ExitSuccess = "0" :: String
    exitLabel (ExitFailure n) = Protolude.show n

-- | Get a Terraform "diff", actually the results of @terraform plan@.
diff :: (MonadLogger m, MonadIO m, MonadError Error m) => Config -> m (Maybe Diff)
diff terraformConfig = do
  -- Run 'init' before the diff because there's no better way of asserting
  -- that we are running in an initialised workspace.
  initResult <- init terraformConfig
  void $ handleError initResult
  refreshResult <- refresh terraformConfig
  void $ handleError refreshResult
  planResult <- plan terraformConfig
  let planCode = processExitCode planResult
  liftIO $ Prometheus.setGauge (exitGauge planCode) (planExitCode terraformConfig)
  case processExitCode planResult of
    ExitSuccess -> pure Nothing
    ExitFailure 2 -> pure (Just (Diff (processOutput planResult)))
    ExitFailure _ -> gotError planResult
  where
    exitGauge ExitSuccess = 0.0
    exitGauge (ExitFailure n) = fromIntegral n

    handleError (ProcessResult _ _ ExitSuccess out _) = pure out
    handleError failed = gotError failed

    gotError failed = do
      -- It's somewhat unfortunate that this will log an error when the
      -- process fails due to a lock being held. Terraform gives us no
      -- structured way of distinguishing these errors, so we'll just lump it
      -- for now.
      logError $ "Process failed: " <> formatProcessResult failed
      throwError (ProcessError failed)

-- | The diff output from @terraform plan@. Generate this with 'diff'.
newtype Diff = Diff ByteString deriving (Eq, Show)

-- | An error that occurs when running Terraform.
newtype Error = ProcessError ProcessResult deriving (Eq, Show)

-- | The result of running a process. Includes a field for describing the
-- process to make HTML rendering easier.
data ProcessResult
  = ProcessResult
  { processTitle :: Text
  , processInfo :: Process.CreateProcess
  , processExitCode :: ExitCode
  , processOutput :: ByteString
  , processError :: ByteString
  } deriving (Eq, Show)


formatProcessResult :: ProcessResult -> Text
formatProcessResult ProcessResult{processTitle, processInfo, processExitCode, processOutput, processError} =
  Protolude.show processTitle <> " " <> status <> ": " <> Protolude.show processExitCode <> "\n" <>
  "Command: " <> command <> "\n" <>
  "Output:\n----\n" <> toS processOutput <> "----\n" <>
  "Error:\n----\n" <> toS processError <> "----\n"
  where
    status = case processExitCode of
               ExitSuccess -> "succeeded"
               _ -> "failed"
    command = toS $ case Process.cmdspec processInfo of
                      Process.ShellCommand cmd -> cmd
                      Process.RawCommand cmd args -> Process.showCommandForUser cmd args

-- | Initialize a Terraform working directory.
--
-- TODO: It's possible we want to encode a state transition at the type level.
-- In that context, the inputs would be a working directory and a config file
-- directory, and the output would be a newtype that can only be constructed
-- by init. This would allow functions like plan to require that as a
-- parameter, thus "guaranteeing" that init has been run. 'Guarantee' in scare
-- quotes as it wouldn't prevent someone messing with the .terraform directory
-- behind our backs.
init :: (MonadIO m, MonadLogger m) => Config -> m ProcessResult
init config =
  runTerraform config "init"
    [ toS ("-lock=" ++ Protolude.show (terraformLocking config))
    , toS (terraformPath config)
    ]

-- | Refresh the Terraform state by examining actual infrastructure.
--
-- Run this before 'plan' to ensure your plans are based on reality.
--
-- NOTE: The output of this command might include secrets.
refresh :: (MonadIO m, MonadLogger m) => Config -> m ProcessResult
refresh config =
  runTerraform config "refresh"
    [ toS ("-lock=" ++ Protolude.show (terraformLocking config))
    , toS (terraformPath config)
    ]

-- | Generate a Terraform plan.
plan :: (MonadIO m, MonadLogger m) => Config -> m ProcessResult
plan config =
  runTerraform config "plan"
    [ toS ("-lock=" ++ Protolude.show (terraformLocking config))
    , "-detailed-exitcode"
    , "-refresh=false"
    , toS (terraformPath config)
    ]

-- | Files that contain AWS credentials.
--
-- It's a slightly unusual way of specifying credentials, but it works well
-- with Kubernetes secrets, which mounts secrets as files on disk.
data AWSCredentialsFiles
  = AWSCredentialsFiles
  { accessKeyIdFile :: FilePath
  , secretAccessKeyFile :: FilePath
  } deriving (Eq, Show)

-- | Command-line flags for specifying AWS credentials stored in files.
awsCredentialsFlags :: Opt.Parser AWSCredentialsFiles
awsCredentialsFlags
  = AWSCredentialsFiles
  <$> Opt.option
       Opt.str
       (fold
        [ Opt.long "aws-access-key-id-file"
        , Opt.help "Path to file containing AWS access key ID"
        ])
  <*> Opt.option
       Opt.str
       (fold
        [ Opt.long "aws-secret-access-key-file"
        , Opt.help "Path to file containing AWS secret access key"
        ])

-- TODO: Someone must have built this type already. Find a good library and
-- use that instead.
-- | AWS credentials.
data AWSCredentials
  = AWSCredentials
  { accessKeyId :: ByteString
  , secretAccessKey :: Secret ByteString
  } deriving (Eq, Show)

-- | Load AWS credentials from files.
awsCredentialsFromFiles :: MonadIO io => AWSCredentialsFiles -> io AWSCredentials
awsCredentialsFromFiles credsFiles =
  AWSCredentials
    <$> readSecretFile (accessKeyIdFile credsFiles)
    <*> (Secret <$> readSecretFile (secretAccessKeyFile credsFiles))

-- | Output AWS credentials as environment variables.
awsCredentialsToEnvVars :: AWSCredentials -> [(String, String)]
awsCredentialsToEnvVars AWSCredentials{accessKeyId, secretAccessKey} =
  [ ("AWS_ACCESS_KEY_ID", toS accessKeyId :: String)
  , ("AWS_SECRET_ACCESS_KEY", toS (revealSecret secretAccessKey))
  ]


-- | Wrap up value that's supposed to be secret. This gives us an in-code
-- reminder that we're handling sensitive data, and also makes it harder to
-- accidentally print or store the value.
--
-- XXX: jml is not 100% sure this is a good idea. Might just be a lot of
-- typing (ha!) for no benefit.
newtype Secret a = Secret { revealSecret :: a } deriving (Eq)

instance Show (Secret a) where
  show = const "********"


-- | A GitHub token.
newtype GitHubToken = GitHubToken (Secret ByteString) deriving (Eq, Show)

-- | Read a GitHub token from a file.
gitHubTokenFromFile :: MonadIO io => FilePath -> io GitHubToken
gitHubTokenFromFile = map (GitHubToken . Secret) . readSecretFile

-- | Output GitHub token as environment variables.
--
-- It's only one variable, but we emit it as a list for consistency with
-- 'awsCredentialsToEnvVars'.
gitHubTokenToEnvVars :: GitHubToken -> [(String, String)]
gitHubTokenToEnvVars (GitHubToken token) =
  [ ("GITHUB_TOKEN", toS (revealSecret token)) ]


-- | Read a "secret" from a file that was probably mounted from a Kubernetes secret.
--
-- Strictly loads the file into memory, and splits at the first newline. This
-- latter is an affordance for local development, where it is easy to have a
-- spurious newline at the end of a file.
readSecretFile :: MonadIO io => FilePath -> io ByteString
readSecretFile = map (fst . Char8.break (== '\n')) . liftIO . ByteString.readFile
