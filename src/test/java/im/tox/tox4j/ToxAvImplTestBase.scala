package im.tox.tox4j

import im.tox.tox4j.annotations.NotNull
import im.tox.tox4j.av.{ToxAv, ToxAvTestBase}
import im.tox.tox4j.av.exceptions.ToxAvNewException
import im.tox.tox4j.core.{ToxCore, ToxOptions}
import im.tox.tox4j.core.exceptions.ToxNewException
import org.junit.After

import scala.collection.mutable.ArrayBuffer

abstract class ToxAvImplTestBase extends ToxAvTestBase {

  protected val node: DhtNode = DhtNodeSelector.node

  private final val toxes = new ArrayBuffer[ToxCoreImpl]
  private final val avs = new ArrayBuffer[ToxAvImpl]

  @After def tearDown() {
    avs.foreach(_.close())
    avs.clear()
    toxes.foreach(_.close())
    toxes.clear()
    System.gc()
  }

  @NotNull
  @throws(classOf[ToxNewException])
  protected final def newTox(options: ToxOptions, data: Array[Byte]): ToxCore = {
    val tox = new ToxCoreImpl(options, data)
    toxes += tox
    tox
  }

  @throws(classOf[ToxAvNewException])
  protected final def newToxAv(tox: ToxCore): ToxAv = {
    val av = new ToxAvImpl(tox)
    avs += av
    av
  }

}