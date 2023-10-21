package gitsummary

import cats.data.Validated
import cats.effect.*
import cats.effect.implicits.*
import cats.effect.std.Console
import cats.syntax.all.*
import com.monovore.decline.*
import com.monovore.decline.effect.CommandIOApp
import fs2.Stream
import fs2.io.file.Files
import fs2.io.file.Path
import fs2.io.process.Processes

case class StatusLine(
    x: Char,
    y: Char,
    path: Path,
    originalPath: Option[Path]
)

def parseGitStatusLine(line: String): Either[Throwable, StatusLine] =
  line.toList match {
    case x :: y :: ' ' :: path =>
      Either
        .catchNonFatal(Path(path.mkString))
        .map(path => StatusLine(x, y, path, None))
    case _ => Left(Exception(s"Failed to parse git status line: $line"))
  }

case class RepoStatus(
    repoPath: Path,
    statusLines: List[StatusLine],
    unpushed: Int,
    unpulled: Int
)

class AppImpl[F[_]: Concurrent: Files: Processes: Console]:

  val F = Concurrent[F]

  extension (proc: fs2.io.process.Process[F])
    def dumpOutput: F[Unit] =
      (
        proc.stdout
          .through(fs2.text.utf8.decode)
          .through(fs2.text.lines)
          .evalMap(Console[F].println)
          .compile
          .drain,
        proc.stderr
          .through(fs2.text.utf8.decode)
          .through(fs2.text.lines)
          .evalMap(Console[F].println)
          .compile
          .drain
      ).tupled.void

  def isGitRepo(path: Path): F[Boolean] =
    Files[F].exists(path / ".git")

  def findGitReposBelow(
      root: Path,
      maxDepth: Int,
      maxConcurrency: Int
  ): fs2.Stream[F, Path] =
    Files[F]
      .walk(root, maxDepth, false)
      .filterNot(_.fileName.show.startsWith("."))
      .parEvalMap(maxConcurrency)(path => isGitRepo(path).tupleLeft(path))
      .mapFilter {
        case (p, true)  => p.some
        case (_, false) => none
      }

  def getUnpushed(path: Path): F[Int] =
    fs2.io.process
      .ProcessBuilder("git", "log", "--pretty=format:'%h'", "@{u}..")
      .withWorkingDirectory(path)
      .spawn
      .use(proc =>
        proc.exitValue
          .reject {
            case n if n != 0 => Exception("non-zero exit code")
          }
          .onError(_ => proc.dumpOutput) *> proc.stdout
          .through(fs2.text.utf8.decode)
          .through(fs2.text.lines)
          .compile
          .count
          .map(_.toInt)
      )

  def getUnpulled(path: Path): F[Int] =
    fs2.io.process
      .ProcessBuilder("git", "log", "--pretty=format:'%h'", "..@{u}")
      .withWorkingDirectory(path)
      .spawn
      .use(proc =>
        proc.exitValue
          .reject {
            case n if n != 0 => Exception("non-zero exit code")
          }
          .onError(_ => proc.dumpOutput) *> proc.stdout
          .through(fs2.text.utf8.decode)
          .through(fs2.text.lines)
          .compile
          .count
          .map(_.toInt)
      )

  def getStatusLines(path: Path): F[List[StatusLine]] =
    fs2.io.process
      .ProcessBuilder("git", "status", "--porcelain=v1")
      .withWorkingDirectory(path)
      .spawn
      .use { proc =>
        proc.exitValue
          .reject {
            case n if n != 0 => Exception("non-zero exit code")
          }
          .onError(_ => proc.dumpOutput) *> proc.stdout
          .through(fs2.text.utf8.decode)
          .through(fs2.text.lines)
          .filter(_.nonEmpty)
          .map(parseGitStatusLine)
          .evalMap(F.fromEither(_))
          .compile
          .toList

      }

  def getRepoStatus(path: Path): F[RepoStatus] =
    (getStatusLines(path), getUnpulled(path), getUnpushed(path)).parTupled.map:
      case (lines, unpulled, unpushed) =>
        RepoStatus(path, lines, unpulled, unpushed)

  def getRepoStatusesBelow(
      path: Path,
      maxDepth: Int,
      maxConcurrency: Int
  ): Stream[F, RepoStatus] =
    findGitReposBelow(path, maxDepth, maxConcurrency)
      .parEvalMapUnordered(maxConcurrency)(path =>
        getRepoStatus(path)
          .onError(t =>
            Console[F].println(s"Failed to get repo status for $path")
          )
          .attempt
      )
      .collect { case Right(a) => a }

object Main
    extends CommandIOApp(
      "git-summary",
      "git-summary prints a summary of git repo statuses of all repos under a given root."
    ):

  val pathArg = Opts
    .argument[String]()
    .mapValidated(s =>
      Validated.catchNonFatal(Path(s)).leftMap(_.getMessage).toValidatedNel
    )

  val maxDepthArg = Opts
    .option[Int](
      "max-depth",
      "the maximum depths of subdirectories to search for git repos",
      "g"
    )
    .withDefault(3)

  val maxConcurrencyArg = Opts
    .option[Int](
      "max-concurrency",
      "the maximum degree of concurrency when getting repo statuses",
      "p"
    )
    .withDefault(128)

  override def main: Opts[IO[ExitCode]] =
    (pathArg, maxDepthArg, maxConcurrencyArg).mapN:
      case (root, maxDepth, maxConcurrency) =>
        AppImpl[IO]
          .getRepoStatusesBelow(root, maxDepth, maxConcurrency)
          .evalMap(IO.println)
          .compile
          .drain
          .as(ExitCode.Success)
